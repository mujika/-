# RaveMorph — RAVE 潜在補間による音色モーフィングの検証アプリ

iPhone で「マイク入力 A」と「バンドルした音 B」の間を、スライダー α でリアルタイムに行き来する試作です。製品ではなく技術検証で、知りたいのは次の3点です。

1. RAVE の潜在補間によるモーフが iPhone 実機でリアルタイムに動くか
2. 1ブロックあたりの推論時間(encode + decode)
3. α を動かしたときの音の変化が、聴いて意味のあるものか

> **現状: このコードは一度もコンパイル・実行されていません。**
> Swift も Xcode もない Linux 環境で書かれ、Hugging Face にも接続できなかったため、
> モデルの実物も未確認です。下の「確認できたこと・できていないこと」を先に読んでください。

## 構成

```
マイク → AVAudioSinkNode → inRing → [推論スレッド] → outRing → AVAudioSourceNode → 出力
B.wav → 起動時に潜在列へ事前エンコード ─────┘
SwiftUI Slider → α(アトミック変数)──────────┘
```

| 場所 | 内容 |
| --- | --- |
| `MorphCore/` | Swift パッケージ(iOS 18 / macOS 15)。リングバッファ、モデル呼び出し、モーフ処理、推論スレッド。`swift test` の対象 |
| `App/` | SwiftUI アプリ本体(薄い層)。`project.yml` から XcodeGen でプロジェクトを生成 |
| `scripts/fetch_models.py` | Hugging Face からモデルを `Models/` に取得(`Models/` は .gitignore 済み) |

`MorphCore` の中身:

- `RingBuffer.swift` — `Atomic<Int>` の head / tail による SPSC ロックフリーリングバッファと `AtomicFloat`
- `RaveCodec.swift` — encoder / decoder の読み込み、メタデータ照合、状態テンソルの持ち回し
- `MorphProcessor.swift` — 1ブロックの処理(encode → α 平滑化 → 補間 → decode)と B の事前エンコード
- `MorphEngine.swift` — 推論スレッド、リングバッファ、統計。レンダーコールバックから呼ぶのは `capture` / `render` だけ
- `AudioFileIO.swift`、`TestSignals.swift` — wav の読み書きとテスト用合成音

推論スレッドの1周(2048 サンプルごと): inRing から読む → encode して zA → B の潜在列から zB(末尾でループ)→ `alpha += 0.5 * (target - alpha)` → `z = (1-α)·zA + α·zB` → decode → outRing に書く。ノイズ入力はゼロ固定です。

## 手順(Mac)

必要なもの: Xcode 16 以上、[XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)、Python 3。

### 1. モデルを取得する

```sh
python3 scripts/fetch_models.py --list   # まずファイル一覧を見る
python3 scripts/fetch_models.py          # XNNPACK 版の encoder / decoder を Models/ に取得
```

ファイル名は決め打ちしていません(実物を確認できなかったため)。1つに絞れなければ候補を表示して止まるので、`--encoder` / `--decoder` でリポジトリ内パスを指定してください。`export/` と `tools/` のスクリプトも `Models/reference/` に取得します。**入力順・状態の初期値・メソッド名は、ここで `export/` と `tools/check_streaming.py` を読んで確認してください。**

### 2. Mac でテストする

```sh
cd MorphCore
swift test 2>&1 | tee test.log
grep -E '^\[(model|stream|alpha0|timing|listen)\]' test.log
```

テストが確かめること:

| テスト | 内容 |
| --- | --- |
| `RingBufferTests` | 折り返し、満杯、空、破棄、2スレッドでの連番転送 |
| `testModelLayoutMatchesAssumptions` | .pte を読めるか。メソッド名と入出力の数・形状を表示し、想定と照合 |
| `testStreamingRoundTripIsFiniteAudibleAndClickFree` | 2048 サンプルずつ encode → decode。有限値、無音でない、ブロック境界で不連続がない。参考として状態を毎回リセットした場合と比較 |
| `testDeterministic` | 同じ入力で同じ出力になるか |
| `testAlphaZeroEqualsPlainRoundTrip` | α = 0 の出力が、A をそのまま encode → decode した結果と一致するか |
| `testAlphaChangesOutput` | α = 0 / 0.5 / 1 で出力が変わるか |
| `testInferenceTimePerBlock` | encode / decode / 合計の平均と最大(ms) |

モデルがないとモデル系のテストは**失敗**します(スキップにはしていません)。`[listen]` の行に出る wav(一時フォルダ)を聴くと、往復後の音と α ごとの音を耳で確かめられます。

形状が想定と違った場合、`RaveCodec` は実物のメタデータを含むエラーを出します。状態サイズとノイズ次元はメタデータから取るので、違っていても動く可能性がありますが、入力の**順番**が違う場合は `RaveCodec.swift` を直す必要があります。

### 3. シミュレータ向けにビルドする

```sh
cd App
xcodegen generate
xcodebuild -project RaveMorph.xcodeproj -scheme RaveMorph \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### 4. 実機で動かす

1. `App/Signing.xcconfig.example` を `App/Signing.xcconfig` にコピーし、Team ID と Bundle ID を入れる。
2. B に使う音声があれば `App/Resources/B.wav`(44.1kHz)として置く。なければ合成音が使われます。
3. `Models/` にモデルがある状態で `cd App && xcodegen generate`(モデルと B.wav はこの時点で存在するものだけがプロジェクトに入ります)。
4. `open RaveMorph.xcodeproj` し、iPhone(iOS 18 以上)を選んで Run。初回は iPhone 側で開発元を信頼する操作が必要です。
5. **有線イヤホンをつなぐ。** スピーカーだとハウリングします。Bluetooth は 44.1kHz にならずエラーで止まることがあります。
6. 「開始」を押し、マイクを許可。読み込み表示が消えたら、マイクに音を入れながらスライダーを動かす。

見るところ:

- **リアルタイムに動くか** — 「出力不足」の回数が増え続けないか。音が途切れないか。
- **推論時間** — 「直近平均 / 直近最大」が 46.4 ms(1ブロック)を十分下回っているか。Release ビルドでも測ってください。
- **音の変化** — α = 0 で自分の音(RAVE を通った音)、α = 1 で B、途中で中間的な音になるか。同じ α に戻すと同じ音に戻るか。

## 確認できたこと・できていないこと

### 確認できたこと(この環境で実際に見たもの)

- ExecuTorch の SwiftPM ブランチ **`swiftpm-1.5.1` は存在しない**。1.5 系は `swiftpm-1.5.0` のみ、その次は `swiftpm-1.6.0`。`MorphCore/Package.swift` は暫定で `swiftpm-1.5.0` を指しています(**要確認**。変えるのは1行)。
- `swiftpm-1.5.0` の `Package.swift` に、プロダクト `executorch` / `backend_xnnpack` / `kernels_optimized` / `backend_coreml` があり、最低 iOS 17 / macOS 14 であること。
- ExecuTorch v1.5.0 のソース(`extension/apple/ExecuTorch/Exported/`)で、使っている Swift API のシグネチャ: `Module(filePath:)`、`load()`、`load(_:)`、`methodNames()`(`Set<String>`)、`methodMetadata(_:)`、`execute(_:_:)`、`Tensor<Float>(_:shape:)`、`Value.tensor()`、`Tensor.scalars()`(1.5.0 では throws ではない)。
- `scripts/fetch_models.py` が Python として構文エラーなく読めること(実行はしていません)。

### 確認できていないこと(すべて)

- **`swift test` は実行していない。** コンパイルが通るかも未確認。
- **`xcodebuild` も XcodeGen も実行していない。** `project.yml` の書式も未検証。
- **モデルの実物を見ていない。** Hugging Face のファイル一覧、.pte のファイル名、メソッド名(`forward` を仮定)、入出力の順番と形状、状態の初期値(ゼロを仮定)は、依頼文の記述のままです。
- `-all_load` をパッケージの `linkerSettings` とアプリの `OTHER_LDFLAGS` の両方に入れているが、これで XNNPACK とカーネルが登録されるかは未確認。
- 実機での動作、推論時間、音。

### 未着手

- Core ML 版 .pte との推論時間の比較(任意項目)。`fetch_models.py --backend coreml` で取得まではできますが、`backend_coreml` のリンクと比較用テストは入れていません。

## 既知の制限

- 遅延はブロック長だけで約 46 ms あり、α の変化も同じ刻みです。低遅延化は範囲外。
- ハードウェアが 44.1kHz にならない場合はエラー表示で止まります(リサンプルなし)。
- 推論スレッドは毎ブロック配列を確保します(まず動かすことを優先)。時間に余裕がなければ `Tensor(bytesNoCopy:)` で使い回す余地があります。
- 推論スレッドは入力待ちを 1 ms のスリープでポーリングしています。
- 読み込み中に「停止」を押すと、読み込みが終わるまで UI が止まります。

## ライセンス上の注意

モデルとエクスポートスクリプト(anira-project/rave-magnetic-resonator-piano)は CC BY-NC 4.0(非商用)です。検証用途に限り、モデルファイルはこのリポジトリにコミットしません。
