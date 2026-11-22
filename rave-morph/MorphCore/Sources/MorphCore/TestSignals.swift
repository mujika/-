import Foundation

/// 実際の B.wav が用意できるまでの、テスト用の合成音。
public enum TestSignals {
    /// 減衰する倍音つきの音を並べたもの(ピアノ風の打鍵音の代用)。
    public static func decayingNotes(seconds: Double = 6, sampleRate: Double = 44100) -> [Float] {
        let midi: [Double] = [60, 64, 67, 72, 67, 64, 62, 65, 69, 74, 69, 65]
        let noteLength = Int(sampleRate * 0.5)
        let total = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let note = (i / noteLength) % midi.count
            let t = Double(i % noteLength) / sampleRate
            let f = 440 * pow(2, (midi[note] - 69) / 12)
            let attack = min(t / 0.005, 1)
            let envelope = attack * exp(-4 * t)
            var s = 0.0
            for h in 1...5 {
                s += sin(2 * .pi * f * Double(h) * t) / Double(h * h)
            }
            out[i] = Float(0.4 * envelope * s)
        }
        return out
    }

    /// ゆっくり音程が動く持続音(テストで A の代わりに使う)。
    public static func glidingTone(seconds: Double = 4, sampleRate: Double = 44100) -> [Float] {
        let total = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: total)
        var phase = 0.0
        for i in 0..<total {
            let t = Double(i) / sampleRate
            let f = 220 * pow(2, 0.5 * sin(2 * .pi * 0.25 * t))
            phase += 2 * .pi * f / sampleRate
            out[i] = Float(0.3 * (sin(phase) + 0.3 * sin(2 * phase) + 0.1 * sin(3 * phase)))
        }
        return out
    }
}
