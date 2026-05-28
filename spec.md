# Godot WebXR ピアノ練習支援システム — Claude Code 向け仕様書

## プロジェクト概要

Meta Quest 3 のフルカラーパススルーを活用し、現実のピアノに仮想ガイドをオーバーレイ表示するAR練習支援アプリ。
**Godot 4.x** でHTMLエクスポートし、**Meta Quest Browser** 上でWebXRとして動作させる。

### 開発方針（最重要）

- **段階的確認を徹底する。** 各フェーズを実装したら必ずQuest 3実機で動作確認してから次へ進む。一気に実装しない。
- **各フェーズはシンプルに保つ。** 確認ポイントが明確な最小実装を優先する。
- **一度に複数の未知要素を組み合わせない。** ARとMIDIとOSMDを同時に導入しない。

---

## 技術スタック

| 項目 | 技術 |
|:---|:---|
| エンジン | Godot 4.3 以上（4.2はWebXRに既知バグあり） |
| エクスポート先 | HTML5（Web export） |
| 実行環境 | Meta Quest 3 / Meta Quest Browser |
| AR / パススルー | WebXR Device API `immersive-ar` セッション（Godot組み込みの `WebXRInterface` を使用） |
| MIDI通信 | Web MIDI API（Godotから `JavaScriptBridge` 経由で呼び出す） |
| 楽譜解析・描画 | OpenSheetMusicDisplay (OSMD)（Phase 4以降。JSブリッジ経由） |
| スクリプト言語 | GDScript（メイン） + JavaScript（WebXR/MIDI/OSMDのブリッジ部分） |

### JavaScriptBridge について

Godot 4 のWebエクスポートでは `JavaScriptBridge` クラスでブラウザのJS APIを呼び出せる。
Web MIDI API・OSMD はGodot側から直接叩けないため、このブリッジを経由する。

```gdscript
# 例: JSの関数を呼ぶ
JavaScriptBridge.eval("navigator.requestMIDIAccess().then(...)")

# 例: JSコールバックをGodotで受け取る
var cb = JavaScriptBridge.create_callback(func(args): print(args))
```

---

## フェーズ別実装計画

### Phase 0 — 環境構築・動作確認

**ゴール:** Quest 3のブラウザでGodotエクスポートのHTMLが開き、3Dオブジェクトが表示される。

**やること:**
1. Godot 4.3以上をインストール
2. 空の3Dシーンを作成（MeshInstance3D で立方体など）
3. Web Export テンプレートをインストールし、HTMLエクスポート
4. ローカルHTTPSサーバーを立ち上げる（**HTTPSは必須**。WebXRはセキュアコンテキストでのみ動作）
   - 推奨: `mkcert` でローカル証明書を作成 + `python -m http.server` or `caddy`
5. Quest 3でそのURLを開き、画面が表示されることを確認

**確認ポイント:**
- [ ] ブラウザで3Dシーンが表示される
- [ ] HTTPSで接続できている（アドレスバーに鍵マーク）
- [ ] コンソールにエラーが出ていない

**注意事項:**
- Godot WebエクスポートはSharedArrayBuffer を使うため、サーバーに以下のHTTPヘッダが必要:
  ```
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
  ```
- Quest Browser でWebXR を使うには、ブラウザの設定でWebXRを有効化する必要がある場合がある

---

### Phase 1a — WebXR パススルーAR起動

**ゴール:** Quest 3で「ARセッション開始」ボタンを押すと、カメラパススルーで現実が見える状態になる。

**やること:**
1. `WebXRInterface` を取得・初期化
2. `immersive-ar` モードでXRセッションを開始するボタンをUIに配置
3. セッション開始後、背景が透過（現実のパススルー映像）になることを確認
4. AR空間に簡単なオブジェクト（半透明の球など）を浮かせる

**GDScript 実装イメージ:**

```gdscript
extends Node3D

var webxr_interface: WebXRInterface

func _ready():
    webxr_interface = XRServer.find_interface("WebXR")
    if webxr_interface:
        webxr_interface.session_mode = "immersive-ar"
        webxr_interface.requested_reference_space_types = "local-floor"
        webxr_interface.required_features = "local-floor"
        webxr_interface.session_supported.connect(_on_session_supported)
        webxr_interface.check_capabilities()

func _on_session_supported(session_mode: String, supported: bool):
    if supported:
        get_viewport().use_xr = true
        webxr_interface.initialize()
```

**確認ポイント:**
- [ ] ボタンタップでARセッションが開始する
- [ ] 現実の映像がパススルーで見える
- [ ] 3Dオブジェクトが現実空間に浮かんで見える
- [ ] フレームレートが快適（目安: 60fps以上）

---

### Phase 1b — Web MIDI API 受信

**ゴール:** ピアノを弾いたMIDI信号をGodotが受信し、デバッグ表示できる。

**前提:** ピアノとQuest 3をUSB-Cで有線接続（OTGケーブル経由）。

**やること:**
1. HTML内に `<script>` でMIDI初期化コードを埋め込む（Godotのカスタムヘッダー機能を使用）
2. `navigator.requestMIDIAccess()` でMIDIデバイスを取得
3. Note On / Note Off イベントをGodotに `JavaScriptBridge` 経由で通知
4. Godot側でNote Number・Velocity を受け取り、ラベルに表示する

**JS → Godot 通知パターン:**

```javascript
// JS側（HTMLヘッダーに埋め込む）
navigator.requestMIDIAccess().then(function(access) {
    access.inputs.forEach(function(input) {
        input.onmidimessage = function(msg) {
            const [status, note, velocity] = msg.data;
            // GodotのAutoloadに定義したグローバル関数を呼ぶ
            window.godot_midi_callback(status, note, velocity);
        };
    });
});
```

```gdscript
# Godot側（Autoload: MidiReceiver.gd）
func _ready():
    # JSから呼べるようにグローバルに登録
    var cb = JavaScriptBridge.create_callback(_on_midi_message)
    JavaScriptBridge.set_interface("godot_midi_callback", cb)

func _on_midi_message(args):
    var status = int(args[0])
    var note   = int(args[1])
    var velocity = int(args[2])
    emit_signal("note_received", status, note, velocity)
```

**確認ポイント:**
- [ ] Quest 3 にUSB接続したピアノが認識される
- [ ] 鍵盤を押すとGodot上のデバッグ表示に Note Number が出る
- [ ] Note On / Note Off が正しく区別される

---

### Phase 2 — AR空間に仮想鍵盤を配置・MIDI連動

**ゴール:** AR空間に88鍵の仮想鍵盤モデルを表示し、MIDI入力に連動して鍵盤が光る。

**やること:**
1. 白鍵52個・黒鍵36個の `MeshInstance3D` を並べて88鍵モデルを生成（コードで動的生成）
2. 簡易キャリブレーションUI: コントローラー（またはハンド）で位置・スケール・角度を調整できる
3. Phase 1b のMIDI受信と連動して、押された鍵に対応する MeshInstance3D の `Emission` を光らせる
4. 調整した位置は `ProjectSettings` or ローカルストレージに保存する

**キャリブレーション方針（シンプル版）:**
- 起動時に仮想鍵盤がデフォルト位置に出る
- コントローラーのスティックで位置・回転を調整
- Aボタンで確定・保存

**確認ポイント:**
- [ ] 仮想鍵盤が現実のピアノとほぼ重なるように配置できる
- [ ] 鍵盤を弾くと対応する仮想キーが光る
- [ ] 光り方がわかりやすい（色・強度）
- [ ] パフォーマンスが問題ない（88個のMeshでも快適か）

---

### Phase 3 — ステップ実行ロジック（Wait for Input）

**ゴール:** 「次に弾く音」をハイライト → 正解入力で次へ進む、という練習フローが動く。

**音符データ形式（Phase 3はJSONで手書き。OSMDは使わない）:**

```json
{
  "title": "きらきら星",
  "notes": [
    {"note": 60, "finger": 1},
    {"note": 60, "finger": 1},
    {"note": 67, "finger": 5},
    {"note": 67, "finger": 5}
  ]
}
```

**やること:**
1. JSONファイルを読み込んで音符リストを取得
2. 現在の音符に対応する仮想鍵盤を「次に弾く色」（例: 緑）でハイライト
3. MIDI入力を待ち、正解音が来たら次の音符へ
4. 不正解音は赤くフラッシュして通知
5. 曲の終わりまで到達したら完了メッセージ

**ステートマシン（シンプル）:**
```
IDLE → WAITING_INPUT → (正解) → 次の音符へ / (不正解) → フラッシュ → WAITING_INPUT
```

**確認ポイント:**
- [ ] ハイライトが正しい鍵盤に表示される
- [ ] 正解・不正解の判定が正確
- [ ] 1曲分の練習フロー（最初から最後まで）が破綻なく動く
- [ ] テンポを気にせず自分のペースで弾き進められる

---

### Phase 4 — AR譜面 + ハンドトラッキングUI（Phase 1〜3安定後）

**ゴール:** OSMDで描画した楽譜をAR空間に浮かべ、ハンドジェスチャーで操作できる。

**やること:**
1. OSMDをJSで初期化し、MusicXMLを `<canvas>` に描画
2. その `<canvas>` を `JavaScriptBridge` 経由でGodotに画像データとして渡し、`ImageTexture` に変換
3. `Quad` メッシュにそのテクスチャを貼り、AR空間の適切な位置（鍵盤の奥など）に配置
4. Phase 3の進行ロジックと連動して現在演奏中の音符をハイライト
5. `XRHandModifier3D` でハンドトラッキングを有効化し、指先と仮想UIの当たり判定を実装

**確認ポイント:**
- [ ] AR空間に楽譜が浮かんで見える
- [ ] 演奏に合わせて現在の音符がハイライトされる
- [ ] 手のジェスチャーでUI操作できる

---

## 非機能要件

| 項目 | 内容 |
|:---|:---|
| HTTPS必須 | WebXRおよびWeb MIDI APIはセキュアコンテキスト（HTTPS）でのみ動作 |
| HTTPヘッダー | `Cross-Origin-Opener-Policy: same-origin` / `Cross-Origin-Embedder-Policy: require-corp` が必要 |
| パフォーマンス | Quest 3 で 72fps 以上を目標。ドローコール削減（MeshInstance3Dのマルチメッシュ化など）を検討 |
| 装着時間 | Quest 3は約515g。1セッションは15〜20分以内を推奨。メニューで練習範囲を区切れるようにする |
| エラー処理 | MIDIデバイス未接続・WebXR非対応ブラウザなどに対してわかりやすいフォールバックUIを用意する |

---

## ディレクトリ構成（想定）

```
piano_ar/
├── project.godot
├── export_presets.cfg
├── scenes/
│   ├── Main.tscn          # エントリーポイント
│   ├── Keyboard.tscn      # 88鍵モデル
│   ├── Calibration.tscn   # キャリブレーションUI
│   └── HUD.tscn           # 譜面・スコア表示
├── scripts/
│   ├── main.gd
│   ├── keyboard.gd        # 鍵盤生成・発光制御
│   ├── midi_receiver.gd   # JavaScriptBridgeでMIDI受信
│   ├── song_player.gd     # ステップ実行ロジック
│   └── score_display.gd   # 楽譜テクスチャ管理
├── autoloads/
│   └── GameState.gd       # グローバル状態管理
├── assets/
│   ├── songs/
│   │   └── sample.json    # 音符データ（Phase 3用）
│   └── musicxml/
│       └── sample.xml     # 楽譜データ（Phase 4用）
└── web/
    └── midi_bridge.js     # Web MIDI API ブリッジ（カスタムHTMLヘッダー用）
```

---

## Claude Codeへの指示

このspec.mdをプロジェクトルートに置き、以下のように進めてください。

1. **Phase 0から始める。** `project.godot` と空の3Dシーンを作成し、エクスポート設定まで行う。
2. **各Phaseの「確認ポイント」をすべて満たしてから次へ進む。**
3. **実機確認が必要なタイミングを明示する。** 「ここでQuest 3で確認してください」と伝えること。
4. **一度に多くのコードを生成しない。** 確認ポイントごとに止まり、OKが出たら次の実装に進む。
5. **既知の問題は事前に警告する。** たとえば「このGodotバージョンでは〇〇のバグがある」など。
