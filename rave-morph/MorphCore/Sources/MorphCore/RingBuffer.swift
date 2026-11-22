import Synchronization

/// 単一プロデューサ・単一コンシューマのロックフリー Float リングバッファ。
///
/// `write` は1本のスレッド、`read` / `discardAll` は別の1本のスレッドからだけ呼ぶこと。
/// どちらもメモリ確保・ロックをしないので、オーディオのレンダーコールバックから呼べる。
public final class SPSCRingBuffer: @unchecked Sendable {
    /// 保持できるサンプル数(2 のべき乗に切り上げ)。
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    // head = 次に読む位置、tail = 次に書く位置。どちらも単調増加(オーバーフローは &+ で許容)。
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    public init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0)
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deallocate()
    }

    /// 読み出せるサンプル数。
    public var availableToRead: Int {
        tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring)
    }

    /// 書き込めるサンプル数。
    public var availableToWrite: Int {
        capacity - availableToRead
    }

    /// 空きがある分だけ書き、書けたサンプル数を返す(プロデューサ側)。
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(count, capacity - (t &- h))
        if n <= 0 { return 0 }
        let start = t & mask
        let first = min(n, capacity - start)
        (storage + start).update(from: source, count: first)
        if n > first {
            storage.update(from: source + first, count: n - first)
        }
        tail.store(t &+ n, ordering: .releasing)
        return n
    }

    /// あるだけ読み、読めたサンプル数を返す(コンシューマ側)。
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = min(count, t &- h)
        if n <= 0 { return 0 }
        let start = h & mask
        let first = min(n, capacity - start)
        destination.update(from: storage + start, count: first)
        if n > first {
            (destination + first).update(from: storage, count: n - first)
        }
        head.store(h &+ n, ordering: .releasing)
        return n
    }

    /// 溜まっている分を捨てる(コンシューマ側)。
    public func discardAll() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// UI スレッドから推論スレッドへ Float を渡すためのアトミック変数(ビットパターンを UInt32 で保持)。
public final class AtomicFloat: Sendable {
    private let bits: Atomic<UInt32>

    public init(_ value: Float) {
        bits = Atomic<UInt32>(value.bitPattern)
    }

    public func load() -> Float {
        Float(bitPattern: bits.load(ordering: .relaxed))
    }

    public func store(_ value: Float) {
        bits.store(value.bitPattern, ordering: .relaxed)
    }
}
