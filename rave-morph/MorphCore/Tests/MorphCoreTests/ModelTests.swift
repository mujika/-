import XCTest
@testable import MorphCore

/// 実物の .pte を使うテスト。先に `python3 scripts/fetch_models.py` で Models/ に取得しておくこと。
/// モデルがない場合はスキップせず失敗させる(確認できていないのに通ったように見えるのを避けるため)。
final class ModelTests: XCTestCase {
    static var modelsDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["MORPH_MODELS_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        // <repo>/MorphCore/Tests/MorphCoreTests/ModelTests.swift → <repo>/Models
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models")
    }

    static var encoderPath: String { modelsDirectory.appendingPathComponent("rave_encoder_xnnpack.pte").path }
    static var decoderPath: String { modelsDirectory.appendingPathComponent("rave_decoder_xnnpack.pte").path }

    private let n = 2048

    private func makeCodec() throws -> RaveCodec {
        try RaveCodec(encoderPath: Self.encoderPath, decoderPath: Self.decoderPath)
    }

    private func blocks(of signal: [Float]) -> [[Float]] {
        (0..<(signal.count / n)).map { Array(signal[($0 * n)..<(($0 + 1) * n)]) }
    }

    private func rms(_ x: [Float]) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
    }

    private func writeForListening(_ samples: [Float], name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("morphcore-\(name).wav")
        try? FileManager.default.removeItem(at: url)
        do {
            try AudioFileIO.writeMono(samples, to: url)
            print("[listen] \(url.path)")
        } catch {
            print("[listen] 書き出し失敗: \(error)")
        }
    }

    // MARK: - 1. 読み込み・メソッド名・形状

    func testModelLayoutMatchesAssumptions() throws {
        // 想定と照合する前に、実物をそのまま表示する。
        for path in [Self.encoderPath, Self.decoderPath] {
            print("[model] methods of \(path): \(try RaveCodec.methodNames(path: path))")
        }
        let encoder = try RaveCodec.describe(path: Self.encoderPath)
        let decoder = try RaveCodec.describe(path: Self.decoderPath)
        print("[model] \(encoder)")
        print("[model] \(decoder)")

        XCTAssertTrue(encoder.methodNames.contains("forward"))
        XCTAssertTrue(decoder.methodNames.contains("forward"))

        XCTAssertEqual(encoder.inputs.map(\.shape), [[1, 1, 2048], [1, 34304]])
        XCTAssertEqual(encoder.outputs.map(\.shape), [[1, 8, 1], [1, 34304]])
        XCTAssertEqual(decoder.inputs.map(\.shape), [[1, 8, 1], [1, 29184], [1, 120, 1]])
        XCTAssertEqual(decoder.outputs.map(\.shape), [[1, 1, 2048], [1, 29184]])
        XCTAssertTrue((encoder.inputs + encoder.outputs + decoder.inputs + decoder.outputs).allSatisfy(\.isFloat))

        // RaveCodec 自身の照合も通ること。
        let codec = try makeCodec()
        XCTAssertEqual(codec.encoderStateSize, 34304)
        XCTAssertEqual(codec.decoderStateSize, 29184)
    }

    // MARK: - 2. ストリーミング(状態の持ち回し)

    func testStreamingRoundTripIsFiniteAudibleAndClickFree() throws {
        let input = TestSignals.glidingTone(seconds: 4)
        let codec = try makeCodec()
        var output: [Float] = []
        for block in blocks(of: input) {
            let z = try codec.encode(block)
            XCTAssertEqual(z.count, 8)
            XCTAssertTrue(z.allSatisfy(\.isFinite))
            let y = try codec.decode(z)
            XCTAssertEqual(y.count, n)
            output += y
        }
        writeForListening(input, name: "roundtrip-input")
        writeForListening(output, name: "roundtrip-output")

        XCTAssertTrue(output.allSatisfy(\.isFinite), "出力に NaN / inf がある")
        // 立ち上がりの 4 ブロックは評価から外す。
        let warmup = 4 * n
        let steady = Array(output[warmup...])
        let level = rms(steady)
        print("[stream] input rms=\(rms(input)) output rms=\(level) peak=\(steady.map(abs).max() ?? 0)")
        XCTAssertGreaterThan(level, 1e-3, "出力がほぼ無音")

        // クリック検査: ブロック境界をまたぐ隣接サンプル差が、ブロック内部の隣接サンプル差の
        // 最大値を大きく超えないこと。状態を持ち回せていないと境界だけ不連続になる。
        var boundaryMax: Float = 0
        var interiorMax: Float = 0
        for i in (warmup + 1)..<output.count {
            let d = abs(output[i] - output[i - 1])
            if i % n == 0 { boundaryMax = max(boundaryMax, d) } else { interiorMax = max(interiorMax, d) }
        }
        print("[stream] adjacent-sample diff: boundary max=\(boundaryMax) interior max=\(interiorMax)")
        XCTAssertLessThanOrEqual(boundaryMax, interiorMax * 1.5 + 1e-4, "ブロック境界で不連続(クリック)の疑い")

        // 参考: 毎ブロック状態をゼロに戻した場合(持ち回しなし)の境界差。
        // 持ち回しが効いていれば、こちらの方が明らかに大きくなるはず。
        let stateless = try makeCodec()
        var broken: [Float] = []
        for block in blocks(of: input) {
            stateless.resetEncoderState()
            stateless.resetDecoderState()
            broken += try stateless.decode(try stateless.encode(block))
        }
        var brokenBoundaryMax: Float = 0
        for i in stride(from: warmup + n, to: broken.count, by: n) {
            brokenBoundaryMax = max(brokenBoundaryMax, abs(broken[i] - broken[i - 1]))
        }
        print("[stream] (reference) boundary max when state is reset every block=\(brokenBoundaryMax)")
        writeForListening(broken, name: "roundtrip-stateless-reference")
        XCTAssertNotEqual(Array(broken[warmup...]), steady, "状態を戻しても出力が同じ = 状態が使われていない疑い")
    }

    /// 同じ入力を2回流して同じ出力になること(ノイズ入力ゼロ・状態ゼロ開始で決定的か)。
    func testDeterministic() throws {
        let input = blocks(of: TestSignals.glidingTone(seconds: 1))
        var runs: [[Float]] = []
        for _ in 0..<2 {
            let codec = try makeCodec()
            var out: [Float] = []
            for block in input { out += try codec.decode(try codec.encode(block)) }
            runs.append(out)
        }
        XCTAssertEqual(runs[0], runs[1])
    }

    // MARK: - 3. α = 0 は素通し(encode → decode)と一致

    func testAlphaZeroEqualsPlainRoundTrip() throws {
        let a = blocks(of: TestSignals.glidingTone(seconds: 2))
        let b = TestSignals.decayingNotes(seconds: 2)

        let plainCodec = try makeCodec()
        var plain: [Float] = []
        for block in a { plain += try plainCodec.decode(try plainCodec.encode(block)) }

        // 実際の使い方どおり、B の事前エンコードに使った codec をそのまま A に使う。
        let morphCodec = try makeCodec()
        let latentsB = try MorphProcessor.preencode(codec: morphCodec, samples: b)
        XCTAssertEqual(latentsB.count, b.count / n)
        let processor = MorphProcessor(codec: morphCodec, latentsB: latentsB)
        var morphed: [Float] = []
        for block in a { morphed += try processor.process(block, targetAlpha: 0) }

        XCTAssertEqual(morphed.count, plain.count)
        var maxDiff: Float = 0
        for i in plain.indices { maxDiff = max(maxDiff, abs(plain[i] - morphed[i])) }
        print("[alpha0] max abs diff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1e-6)
    }

    /// α = 1 は B だけ、α = 0.5 は両者と違う音になること(補間が実際に効いているか)。
    func testAlphaChangesOutput() throws {
        let a = blocks(of: TestSignals.glidingTone(seconds: 2))
        let b = TestSignals.decayingNotes(seconds: 2)
        var outputs: [Float: [Float]] = [:]
        for alpha in [Float(0), 0.5, 1] {
            let codec = try makeCodec()
            let processor = MorphProcessor(codec: codec, latentsB: try MorphProcessor.preencode(codec: codec, samples: b))
            processor.smoothing = 1   // 平滑化なしで即座に目標値へ
            var out: [Float] = []
            for block in a { out += try processor.process(block, targetAlpha: alpha) }
            XCTAssertTrue(out.allSatisfy(\.isFinite))
            outputs[alpha] = out
            writeForListening(out, name: "alpha-\(alpha)")
        }
        XCTAssertNotEqual(outputs[0], outputs[0.5])
        XCTAssertNotEqual(outputs[0.5], outputs[1])
    }

    // MARK: - 4. 推論時間

    func testInferenceTimePerBlock() throws {
        let a = blocks(of: TestSignals.glidingTone(seconds: 6))
        let codec = try makeCodec()
        let processor = MorphProcessor(
            codec: codec,
            latentsB: try MorphProcessor.preencode(codec: codec, samples: TestSignals.decayingNotes(seconds: 2)))

        var encode: [Double] = []
        var decode: [Double] = []
        for (i, block) in a.enumerated() {
            _ = try processor.process(block, targetAlpha: 0.5)
            if i >= 8 {   // 最初の数ブロックはウォームアップとして除く
                encode.append(processor.lastEncodeSeconds * 1000)
                decode.append(processor.lastDecodeSeconds * 1000)
            }
        }
        let total = zip(encode, decode).map(+)
        func average(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }
        let blockMs = 2048.0 / 44100.0 * 1000
        print(String(
            format: "[timing] blocks=%d encode avg=%.2f ms, decode avg=%.2f ms, total avg=%.2f ms, max=%.2f ms (block=%.1f ms)",
            total.count, average(encode), average(decode), average(total), total.max() ?? 0, blockMs))
        // この Mac でリアルタイムに間に合うことだけを確かめる。iPhone の数値は実機で測る。
        XCTAssertLessThan(average(total), blockMs)
    }
}
