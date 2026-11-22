import ExecuTorch
import Foundation

/// モデルについての想定値。すべて Hugging Face のリポジトリ説明から読み取った未検証の値で、
/// `RaveCodec.init` が実物の .pte のメタデータと突き合わせる。
public struct RaveSpec: Sendable {
    public var methodName = "forward"
    public var sampleRate: Double = 44100
    public var blockSize = 2048
    public var latentDim = 8
    /// 説明上の値。実際に使うサイズは .pte のメタデータから取る。
    public var expectedEncoderStateSize = 34304
    public var expectedDecoderStateSize = 29184
    public var expectedNoiseDim = 120

    public init() {}
}

public struct TensorInfo: CustomStringConvertible, Sendable {
    public let index: Int
    public let name: String
    public let shape: [Int]
    public let isFloat: Bool

    public var count: Int { shape.reduce(1, *) }
    public var description: String {
        "#\(index) \(name.isEmpty ? "(no name)" : name) shape=\(shape) \(isFloat ? "float32" : "NOT float32")"
    }
}

public struct ModelDescription: CustomStringConvertible, Sendable {
    public let path: String
    public let methodNames: [String]
    public let method: String
    public let inputs: [TensorInfo]
    public let outputs: [TensorInfo]
    public let backends: [String]

    public var description: String {
        var lines = ["\(URL(fileURLWithPath: path).lastPathComponent)"]
        lines.append("  methods: \(methodNames)")
        lines.append("  \(method) backends: \(backends)")
        lines.append("  inputs:")
        lines += inputs.map { "    \($0)" }
        lines.append("  outputs:")
        lines += outputs.map { "    \($0)" }
        return lines.joined(separator: "\n")
    }
}

public enum RaveError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case methodNotFound(method: String, available: [String], path: String)
    case unexpectedLayout(String)
    case unexpectedOutput(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "モデルファイルがありません: \(path)"
        case .methodNotFound(let method, let available, let path):
            return "メソッド \(method) がありません(\(path))。実際のメソッド: \(available)"
        case .unexpectedLayout(let message):
            return "モデルの入出力が想定と違います: \(message)"
        case .unexpectedOutput(let message):
            return "推論の出力が想定と違います: \(message)"
        }
    }
}

/// RAVE の encoder / decoder(状態テンソル持ち回し形式)。
///
/// ExecuTorch の Module はスレッドセーフではない。生成から破棄まで1本のスレッドだけで使うこと。
public final class RaveCodec {
    public let spec: RaveSpec
    public let encoderDescription: ModelDescription
    public let decoderDescription: ModelDescription

    private let encoder: Module
    private let decoder: Module

    private let encAudioShape: [Int]
    private let encStateShape: [Int]
    private let decLatentShape: [Int]
    private let decStateShape: [Int]
    private let noiseShape: [Int]

    private var encState: [Float]
    private var decState: [Float]
    /// ノイズ入力はゼロ固定(同じ α・同じ入力で同じ音に戻すため)。
    private let noise: [Float]

    public var blockSize: Int { spec.blockSize }
    public var latentDim: Int { spec.latentDim }
    public var encoderStateSize: Int { encState.count }
    public var decoderStateSize: Int { decState.count }

    public init(encoderPath: String, decoderPath: String, spec: RaveSpec = RaveSpec()) throws {
        self.spec = spec
        encoder = try Self.loadModule(path: encoderPath, method: spec.methodName)
        decoder = try Self.loadModule(path: decoderPath, method: spec.methodName)
        encoderDescription = try Self.describe(module: encoder, path: encoderPath, method: spec.methodName)
        decoderDescription = try Self.describe(module: decoder, path: decoderPath, method: spec.methodName)

        // --- encoder: (audio, state) -> (latents, state) ---
        let ei = encoderDescription.inputs
        let eo = encoderDescription.outputs
        guard ei.count == 2, eo.count == 2,
              ei.allSatisfy(\.isFloat), eo.allSatisfy(\.isFloat),
              ei[0].count == spec.blockSize,
              eo[0].count == spec.latentDim,
              eo[1].count == ei[1].count
        else {
            throw RaveError.unexpectedLayout(
                "encoder は (audio[\(spec.blockSize)], state) -> (latents[\(spec.latentDim)], state) を想定。実物:\n\(encoderDescription)")
        }
        encAudioShape = ei[0].shape
        encStateShape = ei[1].shape

        // --- decoder: (latents, state, noise) -> (audio, state) ---
        let di = decoderDescription.inputs
        let dout = decoderDescription.outputs
        guard di.count == 3, dout.count == 2,
              di.allSatisfy(\.isFloat), dout.allSatisfy(\.isFloat),
              di[0].count == spec.latentDim,
              dout[0].count == spec.blockSize,
              dout[1].count == di[1].count
        else {
            throw RaveError.unexpectedLayout(
                "decoder は (latents[\(spec.latentDim)], state, noise) -> (audio[\(spec.blockSize)], state) を想定。実物:\n\(decoderDescription)")
        }
        decLatentShape = di[0].shape
        decStateShape = di[1].shape
        noiseShape = di[2].shape

        encState = [Float](repeating: 0, count: ei[1].count)
        decState = [Float](repeating: 0, count: di[1].count)
        noise = [Float](repeating: 0, count: di[2].count)
    }

    /// 状態をゼロに戻す(初期値ゼロは仮定。README 参照)。
    public func resetEncoderState() {
        for i in encState.indices { encState[i] = 0 }
    }

    public func resetDecoderState() {
        for i in decState.indices { decState[i] = 0 }
    }

    /// 音声1ブロック(blockSize サンプル)を潜在ベクトル(latentDim 個)にする。
    public func encode(_ audio: [Float]) throws -> [Float] {
        precondition(audio.count == spec.blockSize)
        let x = Tensor<Float>(audio, shape: encAudioShape)
        let s = Tensor<Float>(encState, shape: encStateShape)
        let outputs = try encoder.execute(spec.methodName, [x, s])
        guard outputs.count == 2,
              let z: Tensor<Float> = outputs[0].tensor(),
              let newState: Tensor<Float> = outputs[1].tensor(),
              z.count == spec.latentDim,
              newState.count == encState.count
        else {
            throw RaveError.unexpectedOutput("encoder の出力数または形状")
        }
        // 出力テンソルは次の実行で上書きされ得るので、すぐコピーする。
        encState = newState.scalars()
        return z.scalars()
    }

    /// 潜在ベクトル(latentDim 個)を音声1ブロックにする。
    public func decode(_ latents: [Float]) throws -> [Float] {
        precondition(latents.count == spec.latentDim)
        let z = Tensor<Float>(latents, shape: decLatentShape)
        let s = Tensor<Float>(decState, shape: decStateShape)
        let n = Tensor<Float>(noise, shape: noiseShape)
        let outputs = try decoder.execute(spec.methodName, [z, s, n])
        guard outputs.count == 2,
              let audio: Tensor<Float> = outputs[0].tensor(),
              let newState: Tensor<Float> = outputs[1].tensor(),
              audio.count == spec.blockSize,
              newState.count == decState.count
        else {
            throw RaveError.unexpectedOutput("decoder の出力数または形状")
        }
        decState = newState.scalars()
        return audio.scalars()
    }

    // MARK: - 読み込みとメタデータ

    /// .pte を1つ読み、メソッド名と入出力の形状を返す(想定との照合はしない)。
    public static func describe(path: String, method: String = "forward") throws -> ModelDescription {
        let module = try loadModule(path: path, method: method)
        return try describe(module: module, path: path, method: method)
    }

    /// .pte に含まれるメソッド名だけを返す。
    public static func methodNames(path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RaveError.fileNotFound(path)
        }
        let module = Module(filePath: path)
        try module.load()
        return try module.methodNames().sorted()
    }

    private static func loadModule(path: String, method: String) throws -> Module {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RaveError.fileNotFound(path)
        }
        let module = Module(filePath: path)
        try module.load()
        let names = try module.methodNames().sorted()
        guard names.contains(method) else {
            throw RaveError.methodNotFound(method: method, available: names, path: path)
        }
        try module.load(method)
        return module
    }

    private static func describe(module: Module, path: String, method: String) throws -> ModelDescription {
        let meta = try module.methodMetadata(method)
        func infos(_ dict: [Int: TensorMetadata]) -> [TensorInfo] {
            dict.keys.sorted().map { index in
                let t = dict[index]!
                return TensorInfo(index: index, name: t.name, shape: t.shape, isFloat: t.dataType == .float)
            }
        }
        return ModelDescription(
            path: path,
            methodNames: try module.methodNames().sorted(),
            method: method,
            inputs: infos(meta.inputTensorMetadata),
            outputs: infos(meta.outputTensorMetadata),
            backends: meta.backendNames
        )
    }
}
