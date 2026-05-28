# AR Piano — Meta Quest 3 AR Piano Practice App

Meta Quest 3 のフルカラーパススルーを活用し、現実のピアノに発光ガイドをオーバーレイ表示する AR 練習支援アプリです。  
Godot 4 で Web エクスポートし、**Meta Quest Browser** 上で WebXR として動作します。

---

## スクリーンショット

> ピアノの各鍵盤タッチポイントに光る球を配置。演奏中は緑のパルス、待機中は白/青の呼吸アニメーション、ランダムなスパークルで視覚的に鍵盤をガイドします。

---

## 機能

| 機能 | 説明 |
|:---|:---|
| **AR オーバーレイ** | Quest 3 パススルー映像に 88 鍵分の発光球をオーバーレイ表示 |
| **MIDI 連動** | USB 接続のピアノから Web MIDI API 経由で Note On/Off を受信、対応する球が緑にパルス発光 |
| **キャリブレーション** | コントローラーで鍵盤の位置・向き・スケールをリアルタイム調整、操作完了後に自動保存 |
| **位置の永続化** | `bounded-floor` 基準座標で絶対位置を localStorage に保存。HMD を外して再装着しても位置ずれしない |
| **スパークル演出** | 待機中の球がランダムに瞬く金色/青白のフラッシュ |

---

## 動作環境

- **ヘッドセット**: Meta Quest 3（推奨）
- **ブラウザ**: Meta Quest Browser（WebXR `immersive-ar` + `bounded-floor` 対応）
- **MIDI 接続**: USB-C OTG ケーブルでキーボードを直結

---

## 技術スタック

| 項目 | 内容 |
|:---|:---|
| エンジン | Godot 4.6 |
| エクスポート | HTML5 (Web export) |
| XR | WebXR Device API `immersive-ar` / `WebXRInterface` |
| 参照空間 | `bounded-floor`（ガーディアン境界固定）→ `local-floor` フォールバック |
| MIDI | Web MIDI API（`JavaScriptBridge` 経由） |
| 保存 | `localStorage` (キー: `kb_v3`) |
| スクリプト | GDScript + JavaScript（MIDI ブリッジ） |

---

## ディレクトリ構成

```
piano02/
├── project.godot
├── export_presets.cfg
├── Makefile                  # make dev でエクスポート＆サーバー起動
├── scenes/
│   └── Main.tscn             # エントリーポイント
├── scripts/
│   ├── main.gd               # WebXR セッション管理・コントローラー入力
│   └── keyboard.gd           # 88 鍵球生成・MIDI 発光・位置保存
├── autoloads/
│   └── MidiReceiver.gd       # MIDI シグナル中継 (Autoload)
├── server/
│   ├── serve.py              # HTTPS 開発サーバー (SharedArrayBuffer 対応)
│   └── cache_bust.py         # PCK ファイルにタイムスタンプを付与
├── web/
│   └── midi_bridge.js        # Web MIDI API → JavaScriptBridge ブリッジ
└── export/
    └── web/                  # `make export` の出力先
```

---

## セットアップ

### 必要なもの

- [Godot 4.6](https://godotengine.org/) (macOS: `/Applications/Godot.app`)
- Python 3（開発サーバー用）
- [mkcert](https://github.com/FiloSottile/mkcert)（ローカル HTTPS 証明書）
- Meta Quest 3 と同一 LAN 上の Mac/PC

### 証明書の生成（初回のみ）

```bash
cd server
mkcert -key-file key.pem -cert-file cert.pem 192.168.x.x localhost 127.0.0.1
```

> `192.168.x.x` は Mac の LAN IP に置き換えてください。Quest Browser からアクセスするために必要です。

### ビルド＆サーバー起動

```bash
make dev
```

`make dev` は以下を一括実行します:
1. Godot ヘッドレスで Web エクスポート
2. PCK ファイルにタイムスタンプを付与（ブラウザキャッシュバスト）
3. HTTPS 開発サーバーを起動

Quest Browser で `https://192.168.x.x:8443` を開いて **Start AR** をタップします。

---

## コントローラー操作（AR セッション中）

| 操作 | 機能 |
|:---|:---|
| **右トリガー + コントローラー移動** | 鍵盤を平行移動（コントローラーの移動量だけ鍵盤が動く） |
| **A ボタン長押し** | 鍵盤を右回転（長押しで加速） |
| **B ボタン長押し** | 鍵盤を左回転（長押しで加速） |
| **右スティック ↑↓** | 鍵盤スケール拡大/縮小 |

操作を終えると **自動保存**されます。HMD を外して再装着しても位置が復元されます。

---

## MIDI 接続

1. ピアノを USB-C OTG ケーブルで Quest 3 に接続
2. AR セッション開始後、自動的に MIDI デバイスを検出
3. 認識されない場合は画面下の **MIDI Reset** ボタンをタップ

---

## フェーズ計画

| フェーズ | 内容 | 状態 |
|:---|:---|:---|
| Phase 0 | 環境構築・WebXR 動作確認 | ✅ 完了 |
| Phase 1a | WebXR パススルー AR 起動 | ✅ 完了 |
| Phase 1b | Web MIDI API 受信 | ✅ 完了 |
| Phase 2 | AR 空間に鍵盤ガイド配置・MIDI 連動 | ✅ 完了 |
| Phase 3 | ステップ実行練習ロジック（次に弾く音のガイド） | 🔜 次フェーズ |
| Phase 4 | AR 譜面表示・ハンドトラッキング UI | 🔜 将来 |

---

## ライセンス

MIT
