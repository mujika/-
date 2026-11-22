import AVFoundation
import MorphCore
import SwiftUI

/// AVAudioEngine と MorphEngine をつなぐだけの薄い層。
///
/// 信号の流れ:
///   マイク → AVAudioSinkNode → inRing → [推論スレッド] → outRing → AVAudioSourceNode → 出力
@MainActor
final class AudioController: ObservableObject {
    enum Phase { case stopped, loading, running }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var alpha: Float = 0
    @Published private(set) var averageMs: Double = 0
    @Published private(set) var maxMs: Double = 0
    @Published private(set) var blocks = 0
    @Published private(set) var underruns = 0
    @Published private(set) var droppedSamples = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var bSourceName = "合成音"

    private static let sampleRate: Double = 44100

    private let morph = MorphEngine()
    private var engine: AVAudioEngine?
    private var pollTimer: Timer?
    private var starting = false

    func setAlpha(_ value: Float) {
        alpha = value
        morph.alpha.store(value)
    }

    func start() {
        guard phase == .stopped, !starting else { return }
        starting = true
        errorMessage = nil
        Task {
            defer { starting = false }
            guard await AVAudioApplication.requestRecordPermission() else {
                errorMessage = "マイクの使用が許可されていません。設定アプリで許可してください。"
                return
            }
            do {
                try startAudio()
            } catch {
                teardown()
                errorMessage = "\(error)"
            }
        }
    }

    func stop() {
        teardown()
    }

    // MARK: - 開始

    private struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    private func startAudio() throws {
        guard let encoderPath = Bundle.main.path(forResource: "rave_encoder_xnnpack", ofType: "pte"),
              let decoderPath = Bundle.main.path(forResource: "rave_decoder_xnnpack", ofType: "pte")
        else {
            throw SetupError(description:
                "モデル(.pte)がアプリに入っていません。scripts/fetch_models.py を実行してから xcodegen generate とビルドをやり直してください。")
        }
        let bSamples = try loadB()

        let session = AVAudioSession.sharedInstance()
        // defaultToSpeaker は付けない(イヤホンなしのときに受話口から出るので、回り込みが小さい)。
        try session.setCategory(.playAndRecord, mode: .default, options: [])
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setActive(true)
        guard session.sampleRate == Self.sampleRate else {
            throw SetupError(description:
                "ハードウェアのサンプルレートが \(session.sampleRate) Hz です。44100 Hz にできる出力(有線イヤホンなど)に替えてください。")
        }

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate == Self.sampleRate,
              inputFormat.commonFormat == .pcmFormatFloat32,
              inputFormat.channelCount >= 1,
              !inputFormat.isInterleaved || inputFormat.channelCount == 1
        else {
            throw SetupError(description: "マイク入力のフォーマットが想定外です: \(inputFormat)")
        }
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            throw SetupError(description: "出力フォーマットを作れません")
        }

        // レンダーコールバックが掴むのは MorphEngine だけ。中ではリングバッファの読み書きしかしない。
        let morph = self.morph

        let sink = AVAudioSinkNode { _, frameCount, audioBufferList -> OSStatus in
            // 先頭チャンネルだけ使う(Float32。非インターリーブなら mBuffers[0] が ch0)。
            let buffer = audioBufferList.pointee.mBuffers
            if let data = buffer.mData, buffer.mNumberChannels == 1 {
                morph.capture(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            }
            return noErr
        }

        let source = AVAudioSourceNode(format: outputFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            if let data = audioBufferList.pointee.mBuffers.mData {
                morph.render(into: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            }
            return noErr
        }

        engine.attach(sink)
        engine.attach(source)
        engine.connect(engine.inputNode, to: sink, format: inputFormat)
        engine.connect(source, to: engine.mainMixerNode, format: outputFormat)

        morph.alpha.store(alpha)
        morph.start(encoderPath: encoderPath, decoderPath: decoderPath, bSamples: bSamples)
        self.engine = engine
        phase = .loading
        try engine.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func loadB() throws -> [Float] {
        if let url = Bundle.main.url(forResource: "B", withExtension: "wav") {
            bSourceName = "B.wav"
            return try AudioFileIO.loadMono(url: url, expectedSampleRate: Self.sampleRate)
        }
        bSourceName = "合成音"
        return TestSignals.decayingNotes(seconds: 6, sampleRate: Self.sampleRate)
    }

    // MARK: - 状態の反映と停止

    private func poll() {
        guard phase != .stopped else { return }
        switch morph.state {
        case .failed:
            let message = morph.errorMessage ?? "推論スレッドが失敗しました"
            teardown()
            errorMessage = message
            return
        case .running:
            phase = .running
        case .loading, .idle:
            break
        }
        let stats = morph.stats
        averageMs = stats.recentAverageMs
        maxMs = stats.recentMaxMs
        blocks = stats.blocksProcessed
        underruns = stats.outputUnderruns
        droppedSamples = stats.inputDroppedSamples
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        // 先にオーディオを止めてから(コールバックが来なくなってから)推論スレッドを止める。
        engine?.stop()
        engine = nil
        morph.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .stopped
    }
}
