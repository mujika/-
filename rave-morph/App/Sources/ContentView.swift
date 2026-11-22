import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioController()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("RAVE モーフ検証").font(.title2).bold()

            Text("⚠️ イヤホンを使ってください。スピーカーだとマイクと回り込んでハウリングします。")
                .font(.footnote)
                .foregroundStyle(.orange)

            VStack(alignment: .leading) {
                Text(String(format: "α = %.2f", audio.alpha)).monospacedDigit()
                Slider(
                    value: Binding(get: { audio.alpha }, set: { audio.setAlpha($0) }),
                    in: 0...1
                )
                HStack {
                    Text("0 = A(マイク)")
                    Spacer()
                    Text("1 = B(\(audio.bSourceName))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(audio.phase == .stopped ? "開始" : "停止") {
                    if audio.phase == .stopped { audio.start() } else { audio.stop() }
                }
                .buttonStyle(.borderedProminent)
                if audio.phase == .loading {
                    ProgressView()
                    Text("モデル読み込み中…").font(.footnote)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("1ブロック(2048 サンプル ≒ 46.4 ms)の encode + decode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "直近平均 %.2f ms / 直近最大 %.2f ms", audio.averageMs, audio.maxMs))
                Text("処理ブロック \(audio.blocks) / 出力不足 \(audio.underruns) 回 / 入力破棄 \(audio.droppedSamples) サンプル")
                    .font(.caption)
            }
            .monospacedDigit()

            if let error = audio.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding()
    }
}
