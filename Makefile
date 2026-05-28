GODOT   := /Applications/Godot.app/Contents/MacOS/Godot
PRESET  := Web
OUT     := export/web/index.html
SERVER  := server/serve.py

.PHONY: export serve dev stop

# エクスポート + サーバー再起動（通常はこれを使う）
dev: export serve

# Godot ヘッドレスエクスポート
export:
	@echo "==> Exporting..."
	$(GODOT) --headless --export-debug "$(PRESET)" "$(OUT)"
	@python3 server/cache_bust.py
	@echo "==> Export done: $(OUT)"

# サーバー再起動
serve: stop
	@echo "==> Starting HTTPS server..."
	@python3 $(SERVER) &
	@sleep 1
	@echo "==> Server started."

# サーバー停止
stop:
	@pkill -f "$(SERVER)" 2>/dev/null || true
