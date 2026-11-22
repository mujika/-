import XCTest
@testable import MorphCore

final class RingBufferTests: XCTestCase {
    private func write(_ ring: SPSCRingBuffer, _ values: [Float]) -> Int {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count) }
    }

    private func read(_ ring: SPSCRingBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return Array(out.prefix(n))
    }

    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(SPSCRingBuffer(minimumCapacity: 5).capacity, 8)
        XCTAssertEqual(SPSCRingBuffer(minimumCapacity: 8).capacity, 8)
    }

    func testEmpty() {
        let ring = SPSCRingBuffer(minimumCapacity: 8)
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.availableToWrite, 8)
        XCTAssertEqual(read(ring, 4), [])
    }

    func testFull() {
        let ring = SPSCRingBuffer(minimumCapacity: 8)
        XCTAssertEqual(write(ring, [1, 2, 3, 4, 5, 6]), 6)
        // 残り 2 しか入らない
        XCTAssertEqual(write(ring, [7, 8, 9, 10]), 2)
        XCTAssertEqual(ring.availableToRead, 8)
        XCTAssertEqual(ring.availableToWrite, 0)
        XCTAssertEqual(write(ring, [11]), 0)
        XCTAssertEqual(read(ring, 100), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testWrapAround() {
        let ring = SPSCRingBuffer(minimumCapacity: 8)
        XCTAssertEqual(write(ring, [1, 2, 3, 4, 5, 6]), 6)
        XCTAssertEqual(read(ring, 5), [1, 2, 3, 4, 5])
        // 書き込みが末尾をまたぐ
        XCTAssertEqual(write(ring, [7, 8, 9, 10, 11]), 5)
        XCTAssertEqual(ring.availableToRead, 6)
        // 読み出しも末尾をまたぐ
        XCTAssertEqual(read(ring, 6), [6, 7, 8, 9, 10, 11])
        // 何周もさせる
        var next: Float = 0
        var expected: Float = 0
        for _ in 0..<100 {
            let chunk = (0..<5).map { _ -> Float in defer { next += 1 }; return next }
            XCTAssertEqual(write(ring, chunk), 5)
            for v in read(ring, 5) {
                XCTAssertEqual(v, expected)
                expected += 1
            }
        }
    }

    func testDiscardAll() {
        let ring = SPSCRingBuffer(minimumCapacity: 8)
        _ = write(ring, [1, 2, 3])
        ring.discardAll()
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(write(ring, [4, 5]), 2)
        XCTAssertEqual(read(ring, 8), [4, 5])
    }

    /// 2スレッドで連番を流し、欠落・重複・順序違いがないことを確かめる。
    func testTwoThreads() {
        let ring = SPSCRingBuffer(minimumCapacity: 1024)
        let total = 2_000_000
        let done = expectation(description: "consumer finished")
        var failure: String?

        let consumer = Thread {
            var buffer = [Float](repeating: 0, count: 300)
            var expected = 0
            while expected < total {
                let n = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 300) }
                for i in 0..<n {
                    if buffer[i] != Float(expected % 65536) {
                        failure = "index \(expected): got \(buffer[i])"
                        expected = total
                        break
                    }
                    expected += 1
                }
            }
            done.fulfill()
        }
        consumer.start()

        var chunk = [Float](repeating: 0, count: 257)
        var sent = 0
        while sent < total {
            let want = min(chunk.count, total - sent)
            for i in 0..<want { chunk[i] = Float((sent + i) % 65536) }
            sent += chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: want) }
        }
        wait(for: [done], timeout: 60)
        XCTAssertNil(failure)
    }

    func testAtomicFloat() {
        let value = AtomicFloat(0.25)
        XCTAssertEqual(value.load(), 0.25)
        value.store(-1.5)
        XCTAssertEqual(value.load(), -1.5)
    }
}
