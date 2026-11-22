import Foundation

/// 1ブロック分のモーフ処理: encode(A) → 潜在補間 → decode。
/// RaveCodec と同じく、1本のスレッドだけで使うこと。
public final class MorphProcessor {
    public let codec: RaveCodec
    /// 事前エンコードした B の潜在列(1要素 = 1ブロック分 = latentDim 個)。
    public let latentsB: [[Float]]
    /// α の一次平滑化係数: alpha += smoothing * (target - alpha)
    public var smoothing: Float = 0.5

    public private(set) var alpha: Float = 0
    public private(set) var lastEncodeSeconds: Double = 0
    public private(set) var lastDecodeSeconds: Double = 0
    private var indexB = 0

    public init(codec: RaveCodec, latentsB: [[Float]]) {
        precondition(!latentsB.isEmpty)
        precondition(latentsB.allSatisfy { $0.count == codec.latentDim })
        self.codec = codec
        self.latentsB = latentsB
    }

    /// B の音声を blockSize ごとに encode して潜在列にする(端数は捨てる)。
    /// 終わったら encoder の状態をゼロに戻すので、同じ codec をそのまま A に使える。
    public static func preencode(codec: RaveCodec, samples: [Float]) throws -> [[Float]] {
        let n = codec.blockSize
        let blocks = samples.count / n
        guard blocks > 0 else {
            throw RaveError.unexpectedLayout("B の音声が1ブロック(\(n) サンプル)未満です")
        }
        codec.resetEncoderState()
        var latents: [[Float]] = []
        latents.reserveCapacity(blocks)
        for b in 0..<blocks {
            latents.append(try codec.encode(Array(samples[(b * n)..<((b + 1) * n)])))
        }
        codec.resetEncoderState()
        return latents
    }

    /// 入力1ブロックを処理して出力1ブロックを返す。
    public func process(_ block: [Float], targetAlpha: Float) throws -> [Float] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let zA = try codec.encode(block)
        let t1 = DispatchTime.now().uptimeNanoseconds

        let zB = latentsB[indexB]
        indexB = (indexB + 1) % latentsB.count

        let target = min(max(targetAlpha, 0), 1)
        alpha += smoothing * (target - alpha)
        let a = alpha
        var z = [Float](repeating: 0, count: zA.count)
        for i in z.indices {
            z[i] = (1 - a) * zA[i] + a * zB[i]
        }

        let t2 = DispatchTime.now().uptimeNanoseconds
        let out = try codec.decode(z)
        let t3 = DispatchTime.now().uptimeNanoseconds

        lastEncodeSeconds = Double(t1 - t0) / 1e9
        lastDecodeSeconds = Double(t3 - t2) / 1e9
        return out
    }
}
