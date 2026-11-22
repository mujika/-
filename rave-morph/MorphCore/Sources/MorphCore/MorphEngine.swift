import Foundation
import Synchronization

/// 推論スレッドとリングバッファをまとめたもの。
///
/// - オーディオ入力コールバックは `inRing.write` だけを呼ぶ。
/// - オーディオ出力コールバックは `render(into:count:)` だけを呼ぶ。
/// - ExecuTorch の読み込み・B の事前エンコード・推論・破棄は、すべて内部の推論スレッド1本で行う。
public final class MorphEngine: @unchecked Sendable {
    public enum State: Int, Sendable {
        case idle, loading, running, failed
    }

    public struct Stats: Sendable {
        /// 直近(最大 64 ブロック)の encode + decode 時間。
        public var recentAverageMs: Double
        public var recentMaxMs: Double
        public var blocksProcessed: Int
        /// 出力コールバックでデータが足りず無音で埋めた回数。
        public var outputUnderruns: Int
        /// 入力コールバックで inRing が満杯で捨てたサンプル数。
        public var inputDroppedSamples: Int
    }

    public let blockSize: Int
    public let inRing: SPSCRingBuffer
    public let outRing: SPSCRingBuffer
    /// モーフ量の目標値(0 = A、1 = B)。UI スレッドから書く。
    public let alpha = AtomicFloat(0)

    private let stateRaw = Atomic<Int>(State.idle.rawValue)
    private let stopRequested = Atomic<Bool>(false)
    private let averageMicros = Atomic<Int>(0)
    private let maxMicros = Atomic<Int>(0)
    private let blocks = Atomic<Int>(0)
    private let underruns = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    // 以下はレンダーコールバックからは触らない。
    private let lock = NSLock()
    private var errorText: String?
    private var modelText: String?
    private var finished: DispatchSemaphore?

    public init(blockSize: Int = 2048, ringBlocks: Int = 8) {
        self.blockSize = blockSize
        inRing = SPSCRingBuffer(minimumCapacity: blockSize * ringBlocks)
        outRing = SPSCRingBuffer(minimumCapacity: blockSize * ringBlocks)
    }

    public var state: State {
        State(rawValue: stateRaw.load(ordering: .relaxed)) ?? .idle
    }

    public var errorMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return errorText
    }

    /// 読み込んだモデルのメソッド名・形状の説明(読み込み後に入る)。
    public var modelSummary: String? {
        lock.lock(); defer { lock.unlock() }
        return modelText
    }

    public var stats: Stats {
        Stats(
            recentAverageMs: Double(averageMicros.load(ordering: .relaxed)) / 1000,
            recentMaxMs: Double(maxMicros.load(ordering: .relaxed)) / 1000,
            blocksProcessed: blocks.load(ordering: .relaxed),
            outputUnderruns: underruns.load(ordering: .relaxed),
            inputDroppedSamples: droppedSamples.load(ordering: .relaxed)
        )
    }

    // MARK: - レンダーコールバックから呼ぶもの(確保・ロックなし)

    /// 入力コールバック用。入りきらない分は捨てる。
    public func capture(_ source: UnsafePointer<Float>, count: Int) {
        let written = inRing.write(source, count: count)
        if written < count {
            droppedSamples.add(count - written, ordering: .relaxed)
        }
    }

    /// 出力コールバック用。足りない分は無音で埋める。
    public func render(into destination: UnsafeMutablePointer<Float>, count: Int) {
        let got = outRing.read(into: destination, count: count)
        if got < count {
            (destination + got).update(repeating: 0, count: count - got)
            if stateRaw.load(ordering: .relaxed) == State.running.rawValue {
                underruns.add(1, ordering: .relaxed)
            }
        }
    }

    // MARK: - 開始 / 停止(メインスレッドなどから)

    /// 推論スレッドを起動する。モデル読み込みと B の事前エンコードが終わると state が running になる。
    public func start(encoderPath: String, decoderPath: String, bSamples: [Float]) {
        guard finished == nil else { return }
        stopRequested.store(false, ordering: .relaxed)
        averageMicros.store(0, ordering: .relaxed)
        maxMicros.store(0, ordering: .relaxed)
        blocks.store(0, ordering: .relaxed)
        underruns.store(0, ordering: .relaxed)
        droppedSamples.store(0, ordering: .relaxed)
        lock.lock()
        errorText = nil
        modelText = nil
        lock.unlock()
        stateRaw.store(State.loading.rawValue, ordering: .relaxed)

        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [self] in
            run(encoderPath: encoderPath, decoderPath: decoderPath, bSamples: bSamples)
            done.signal()
        }
        thread.name = "MorphEngine.inference"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// 推論スレッドを止めて終了を待つ。オーディオエンジンを止めた後に呼ぶこと。
    public func stop() {
        guard let done = finished else { return }
        stopRequested.store(true, ordering: .relaxed)
        done.wait()
        finished = nil
        if state != .failed {
            stateRaw.store(State.idle.rawValue, ordering: .relaxed)
        }
        outRing.discardAll()   // 出力コールバックは止まっている前提
    }

    // MARK: - 推論スレッド

    private func run(encoderPath: String, decoderPath: String, bSamples: [Float]) {
        do {
            let codec = try RaveCodec(encoderPath: encoderPath, decoderPath: decoderPath)
            lock.lock()
            modelText = "\(codec.encoderDescription)\n\(codec.decoderDescription)"
            lock.unlock()

            let latentsB = try MorphProcessor.preencode(codec: codec, samples: bSamples)
            let processor = MorphProcessor(codec: codec, latentsB: latentsB)

            let n = blockSize
            var block = [Float](repeating: 0, count: n)
            let window = 64
            var recent = [Int](repeating: 0, count: window)
            var recentCount = 0
            var recentIndex = 0

            // 読み込み中に溜まった入力は捨てる(溜めたままだとその分だけ遅延が残る)。
            inRing.discardAll()
            stateRaw.store(State.running.rawValue, ordering: .relaxed)

            while !stopRequested.load(ordering: .relaxed) {
                guard inRing.availableToRead >= n else {
                    usleep(1000)
                    continue
                }
                block.withUnsafeMutableBufferPointer {
                    _ = inRing.read(into: $0.baseAddress!, count: n)
                }
                let out = try processor.process(block, targetAlpha: alpha.load())
                out.withUnsafeBufferPointer {
                    _ = outRing.write($0.baseAddress!, count: n)
                }

                let micros = Int((processor.lastEncodeSeconds + processor.lastDecodeSeconds) * 1e6)
                recent[recentIndex] = micros
                recentIndex = (recentIndex + 1) % window
                recentCount = min(recentCount + 1, window)
                var sum = 0
                var peak = 0
                for i in 0..<recentCount {
                    sum += recent[i]
                    peak = max(peak, recent[i])
                }
                averageMicros.store(sum / recentCount, ordering: .relaxed)
                maxMicros.store(peak, ordering: .relaxed)
                blocks.add(1, ordering: .relaxed)
            }
        } catch {
            lock.lock()
            errorText = "\(error)"
            lock.unlock()
            stateRaw.store(State.failed.rawValue, ordering: .relaxed)
        }
    }
}
