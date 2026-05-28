#!/usr/bin/env python3
"""
エクスポート後に index.pck をタイムスタンプ付きにリネームし、
index.html の GODOT_CONFIG を書き換えてブラウザのキャッシュを強制破棄する。

WASM (34MB) はリネームしない（Godot エンジン自体は変わらないため）。
"""
import os, re, sys, time, glob

web_dir = os.path.join(os.path.dirname(__file__), "..", "export", "web")
html_path = os.path.join(web_dir, "index.html")

# 古いバージョン付き pck を削除
for old in glob.glob(os.path.join(web_dir, "index_v*.pck")):
    os.remove(old)

# 新しいバージョン名
version = time.strftime("%Y%m%d%H%M%S")
new_pck = f"index_v{version}.pck"
src = os.path.join(web_dir, "index.pck")
dst = os.path.join(web_dir, new_pck)

if not os.path.exists(src):
    print(f"ERROR: {src} not found", file=sys.stderr)
    sys.exit(1)

os.rename(src, dst)
print(f"==> PCK renamed: index.pck -> {new_pck}")

# index.html の GODOT_CONFIG を書き換え
html = open(html_path, encoding="utf-8").read()

# mainPack を追加（すでにあれば上書き）
html = re.sub(r'"mainPack":"[^"]*",?\s*', "", html)          # 既存の mainPack を除去
html = re.sub(
    r'("fileSizes":\{")(index[^"]*\.pck)(")',
    rf'\1{new_pck}\3',
    html,
)
html = re.sub(
    r'(const GODOT_CONFIG = \{)',
    rf'\1"mainPack":"{new_pck}",',
    html,
)

open(html_path, "w", encoding="utf-8").write(html)
print(f"==> index.html patched (mainPack={new_pck})")
