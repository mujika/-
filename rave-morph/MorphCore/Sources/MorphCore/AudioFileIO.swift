import AVFoundation

public enum AudioFileError: Error, CustomStringConvertible {
    case sampleRate(actual: Double, expected: Double)
    case unreadable(String)

    public var description: String {
        switch self {
        case .sampleRate(let actual, let expected):
            return "サンプルレートが \(actual) Hz です(\(expected) Hz の wav を使ってください)"
        case .unreadable(let message):
            return "音声ファイルを読めません: \(message)"
        }
    }
}

public enum AudioFileIO {
    /// 音声ファイルをモノラル Float 配列で読む(複数チャンネルは平均)。リサンプルはしない。
    public static func loadMono(url: URL, expectedSampleRate: Double = 44100) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == expectedSampleRate else {
            throw AudioFileError.sampleRate(actual: format.sampleRate, expected: expectedSampleRate)
        }
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var out = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            let p = channels[c]
            for i in 0..<frames { out[i] += p[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames { out[i] *= scale }
        }
        return out
    }

    /// モノラル Float 配列を wav で書く(テスト出力を聴いて確かめる用)。
    public static func writeMono(_ samples: [Float], to url: URL, sampleRate: Double = 44100) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
