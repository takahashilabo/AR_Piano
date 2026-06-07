extends Node3D

# 88鍵盤の白鍵合計幅 (52鍵 × 23mm)
const ORIG_WIDTH    : float = 52.0 * 0.023   # ≈ 1.196 m

# 回転速度 (ラジアン/秒)
const ROT_INIT      : float = 0.3            # 押し始め
const ROT_MAX       : float = 2.0            # 長押し最大
const ROT_ACCEL_SEC : float = 1.5            # ROT_MAX に達するまでの秒数

var webxr_interface: WebXRInterface

var _right_trigger     := 0.0
var _right_stick       := Vector2.ZERO
var _a_held            := 0.0          # A ボタン保持時間 (秒) — 0 = 非押下
var _b_held            := 0.0          # B ボタン保持時間 (秒) — 0 = 非押下
var _restore_pos_frame : int   = 0     # >0 のとき、フレーム後に位置を復元する
var _trigger_was_held  : bool  = false # 前フレームにトリガーが押されていたか
var _trigger_prev_pos  : Vector3 = Vector3.ZERO  # 前フレームのコントローラ位置
var _was_moving        : bool  = false # 前フレームに何かしら操作中だったか

# ── 楽譜キャリブレーション (左コントローラー) ──────────────────────────────
# 鍵盤と同じ操作体系: トリガー=移動 / X(ax)・Y(by)=回転 / スティックY=拡縮
# Score の原点 = 視覚的な中心のため、鍵盤のような half_width 補正は不要で
# シンプルに global_position / rotation.y / scale を直接操作できる。
var _left_trigger          := 0.0
var _left_stick            := Vector2.ZERO
var _score_x_held          := 0.0          # X ボタン保持時間 (秒)
var _score_y_held          := 0.0          # Y ボタン保持時間 (秒)
var _score_trigger_was_held : bool  = false
var _score_trigger_prev_pos : Vector3 = Vector3.ZERO
var _score_was_moving       : bool  = false

# ── ARラベル (黄色いキャリブレーション表示) のオン/オフ切替 ──
# 右コン A+B 同時長押し、または 左コン X+Y 同時長押しで切り替える
# (どちらも単独では既存の回転操作に使われているが、同時押しは未使用のため衝突しない)
const LABEL_TOGGLE_SEC : float = 1.0
var _label_toggle_held : float = 0.0
var _label_visible     : bool  = true


func _ready() -> void:
	$CanvasLayer/Button.pressed.connect(_on_button_pressed)
	$CanvasLayer/MidiResetButton.pressed.connect(_on_midi_reset_pressed)
	MidiReceiver.note_received.connect(_on_note_received)
	MidiReceiver.status_changed.connect(_on_midi_status)

	var rc := $XROrigin3D/RightController
	rc.input_float_changed.connect(_on_right_float)
	rc.input_vector2_changed.connect(_on_right_stick)
	# button_released は使わず _process 内で get_float() ポーリングに統一
	rc.button_pressed.connect(_on_right_button_pressed)

	var lc := $XROrigin3D/LeftController
	lc.input_float_changed.connect(_on_left_float)
	lc.input_vector2_changed.connect(_on_left_stick)

	webxr_interface = XRServer.find_interface("WebXR")
	if webxr_interface:
		webxr_interface.session_mode = "immersive-ar"
		# bounded-floor はガーディアン境界に固定された座標系を使う。
		# セッションをまたいでも絶対座標が一致するため位置ずれが起きない。
		# ガーディアン未設定の場合は local-floor にフォールバック。
		webxr_interface.requested_reference_space_types = "bounded-floor, local-floor"
		webxr_interface.required_features = "local-floor"
		webxr_interface.optional_features = "bounded-floor"
		webxr_interface.session_supported.connect(_on_session_supported)
		webxr_interface.session_started.connect(_on_session_started)
		webxr_interface.session_ended.connect(_on_session_ended)
		webxr_interface.session_failed.connect(_on_session_failed)
		webxr_interface.check_capabilities()
	else:
		$CanvasLayer/Button.text = "WebXR not available"
		$CanvasLayer/Button.disabled = true


# ── コントローラー入力 ────────────────────────────────────────────────────
func _on_right_float(name: String, value: float) -> void:
	if name == "trigger":          # grip は無視、trigger のみ受け付ける
		_right_trigger = value

func _on_right_stick(_name: String, value: Vector2) -> void:
	_right_stick = value

func _on_right_button_pressed(_name: String) -> void:
	pass  # 保存は操作終了時に自動で行う

func _on_left_float(name: String, value: float) -> void:
	if name == "trigger":
		_left_trigger = value

func _on_left_stick(_name: String, value: Vector2) -> void:
	_left_stick = value


# ── メインループ ──────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	# AR 外: MIDI ログ表示
	if OS.has_feature("web") and not get_viewport().use_xr:
		var log := str(JavaScriptBridge.eval("window._midiLog || ''"))
		if log != "":
			$CanvasLayer/MidiLabel.text = log
		return

	if not get_viewport().use_xr:
		return

	# ── AR ラベル追従 ──
	# (use_xr が true になった最初の数フレームで位置を復元)
	var cam := $XROrigin3D/XRCamera3D as XRCamera3D

	# ── 保存済み位置の復元 (セッション開始後 2 フレーム待ってからカメラ相対で適用) ──
	if _restore_pos_frame > 0:
		_restore_pos_frame -= 1
		if _restore_pos_frame == 0:
			($Keyboard as Node3D).load_position_absolute()
			# Score は独自のキャリブレーション保存 (score_v1) があればそれを復元、
			# なければ鍵盤を基準にした相対位置に初期配置する
			if not ($Score as Node3D).load_position_absolute():
				_position_score_relative_to_keyboard()
			_refresh_label()
	var fwd : Vector3 = -cam.global_transform.basis.z.normalized()
	($XROrigin3D/ARLabel as Label3D).global_position = \
		cam.global_position + fwd * 0.8 + Vector3(0.0, -0.1, 0.0)

	var kb  := $Keyboard as Node3D
	var rc  := $XROrigin3D/RightController as XRController3D
	# keyboard.gd は position.x -= half_width で左端を原点にしているため、
	# 中央 = global_position + basis.x * half_w
	var half_w : float = ORIG_WIDTH * 0.5 * kb.scale.x
	var moved := false

	# ── A/B ボタン状態をポーリング ──
	if rc.get_float("ax_button") > 0.5:
		_a_held += delta
	else:
		_a_held = 0.0
	if rc.get_float("by_button") > 0.5:
		_b_held += delta
	else:
		_b_held = 0.0

	# ── トリガー: コントローラの移動量だけ鍵盤を平行移動 ──
	if _right_trigger > 0.3:
		if _trigger_was_held:
			kb.global_position += rc.global_position - _trigger_prev_pos
		_trigger_prev_pos = rc.global_position
		_trigger_was_held = true
		moved = true
	else:
		_trigger_was_held = false

	# ── A/B: 鍵盤の中央を固定して水平回転（長押しで加速）──
	if _a_held > 0.0 or _b_held > 0.0:
		# 回転前の中心ワールド座標を保存
		var center : Vector3 = kb.global_position + kb.transform.basis.x * half_w
		if _a_held > 0.0:
			kb.rotation.y += _rot_speed(_a_held) * delta
		if _b_held > 0.0:
			kb.rotation.y -= _rot_speed(_b_held) * delta
		# 回転後、中心が同じ位置に来るよう左端を再計算
		kb.global_position = center - kb.transform.basis.x * half_w
		moved = true

	# ── スティック Y: スケール調整（中央固定）──
	const STICK_DEAD : float = 0.15
	const SCALE_SPEED : float = 0.4   # 倍率/秒
	const SCALE_MIN   : float = 0.3
	const SCALE_MAX   : float = 3.0
	if abs(_right_stick.y) > STICK_DEAD:
		var center : Vector3 = kb.global_position + kb.transform.basis.x * half_w
		var new_scale : float = clamp(
			kb.scale.x * (1.0 + _right_stick.y * SCALE_SPEED * delta),
			SCALE_MIN, SCALE_MAX
		)
		kb.scale = Vector3.ONE * new_scale
		# スケール変更後は half_w が変わるので再計算
		var new_half_w : float = ORIG_WIDTH * 0.5 * new_scale
		kb.global_position = center - kb.transform.basis.x * new_half_w
		moved = true

	# ── 楽譜キャリブレーション (左コントローラー) ──
	# Score の原点 = 視覚的な中心なので、鍵盤のような half_width 補正は不要
	var score := $Score as Node3D
	var lc     := $XROrigin3D/LeftController as XRController3D
	var score_moved := false

	if lc.get_float("ax_button") > 0.5:
		_score_x_held += delta
	else:
		_score_x_held = 0.0
	if lc.get_float("by_button") > 0.5:
		_score_y_held += delta
	else:
		_score_y_held = 0.0

	# ── ラベル表示切替: 右コン A+B、または左コン X+Y を同時に1秒長押し ──
	if (_a_held > 0.0 and _b_held > 0.0) or (_score_x_held > 0.0 and _score_y_held > 0.0):
		_label_toggle_held += delta
		if _label_toggle_held > LABEL_TOGGLE_SEC:
			_label_visible = not _label_visible
			($XROrigin3D/ARLabel as Label3D).visible = _label_visible
			if _label_visible:
				_refresh_label(">> 表示ON")
			_label_toggle_held = -999.0  # ボタンを離すまで再発火させない
	else:
		_label_toggle_held = 0.0

	# ── トリガー: コントローラの移動量だけ楽譜を平行移動 ──
	if _left_trigger > 0.3:
		if _score_trigger_was_held:
			score.global_position += lc.global_position - _score_trigger_prev_pos
		_score_trigger_prev_pos = lc.global_position
		_score_trigger_was_held = true
		score_moved = true
	else:
		_score_trigger_was_held = false

	# ── X/Y: 中心 (= 原点) を固定して水平回転（長押しで加速）──
	if _score_x_held > 0.0 or _score_y_held > 0.0:
		if _score_x_held > 0.0:
			score.rotation.y += _rot_speed(_score_x_held) * delta
		if _score_y_held > 0.0:
			score.rotation.y -= _rot_speed(_score_y_held) * delta
		score_moved = true

	# ── スティック Y: スケール調整（中心固定、原点基準なので追加補正不要）──
	if abs(_left_stick.y) > STICK_DEAD:
		var new_score_scale : float = clamp(
			score.scale.x * (1.0 + _left_stick.y * SCALE_SPEED * delta),
			SCALE_MIN, SCALE_MAX
		)
		score.scale = Vector3.ONE * new_score_scale
		score_moved = true

	# ── 楽譜の操作終了時に自動保存（リストア完了後のみ）──
	if _restore_pos_frame == 0 and _score_was_moving and not score_moved:
		score.save_position()
		_refresh_label(">> Score Saved")
	_score_was_moving = score_moved

	# ── 操作終了時に自動保存（リストア完了後のみ）──
	if _restore_pos_frame == 0 and _was_moving and not moved:
		($Keyboard as Node3D).save_position()
		_refresh_label(">> Saved")
	elif moved:
		_refresh_label()
	_was_moving = moved


# 長押し時間 → 回転速度 (rad/s)
func _rot_speed(held: float) -> float:
	var t : float = clamp(held / ROT_ACCEL_SEC, 0.0, 1.0)
	return lerp(ROT_INIT, ROT_MAX, t)


# ── 楽譜の配置 (鍵盤を基準にした相対位置) ─────────────────────────────────
# Score のシーン上の座標は絶対位置のプレースホルダに過ぎず、鍵盤のキャリブレー
# ション結果とは無関係。鍵盤の復元が完了したタイミングで、鍵盤を基準にした
# 相対オフセット（少し上・奥）に楽譜を配置し直す。
func _position_score_relative_to_keyboard() -> void:
	var kb    := $Keyboard as Node3D
	var score := $Score as Node3D
	var half_w : float = ORIG_WIDTH * 0.5 * kb.scale.x
	var center : Vector3 = kb.global_position + kb.transform.basis.x * half_w
	var offset : Vector3 = kb.transform.basis * Vector3(0, 0.35, -0.25)
	score.global_position = center + offset
	score.rotation.y = kb.rotation.y


# ── AR ラベル ─────────────────────────────────────────────────────────────
func _refresh_label(extra: String = "") -> void:
	var kb  := $Keyboard as Node3D
	var p   : Vector3 = kb.global_position
	var rot : float   = rad_to_deg(kb.rotation.y)
	var scl : float   = kb.scale.x
	var txt := "[鍵盤]  右コン  Trig:移動 A/B:回転 StickY:拡縮 (自動保存)\n"
	txt += "X:%.2f Y:%.2f Z:%.2f  Rot:%.1f  Scale:%.2f\n" % [p.x, p.y, p.z, rot, scl]

	# ── 楽譜の状態・キャリブレーション情報を表示 ──
	var score := get_node_or_null("Score")
	if score:
		var s3 : Node3D  = score as Node3D
		var sp : Vector3 = s3.global_position
		var srot : float = rad_to_deg(s3.rotation.y)
		var sscl : float = s3.scale.x
		txt += "[楽譜]  左コン  Trig:移動 X/Y:回転 StickY:拡縮 (自動保存)\n"
		txt += "X:%.2f Y:%.2f Z:%.2f  Rot:%.1f  Scale:%.2f\n" % [sp.x, sp.y, sp.z, srot, sscl]
		txt += "[Score] %s" % str(score.get("debug_status"))

	if extra != "":
		txt += "\n" + extra
	($XROrigin3D/ARLabel as Label3D).text = txt


# ── WebXR セッション ──────────────────────────────────────────────────────
func _on_session_supported(session_mode: String, supported: bool) -> void:
	if session_mode == "immersive-ar":
		if not supported:
			$CanvasLayer/Button.text = "AR not supported"
			$CanvasLayer/Button.disabled = true
		else:
			$CanvasLayer/MidiLabel.text = "AR ready"

func _on_session_started() -> void:
	$CanvasLayer.visible = false
	get_viewport().transparent_bg = true
	# ラベルの表示/非表示は前回のユーザー設定 (_label_visible) を引き継ぐ
	($XROrigin3D/ARLabel as Label3D).visible = _label_visible
	# 前セッションの残りフラグをリセット（誤った自動保存を防ぐ）
	_was_moving       = false
	_trigger_was_held = false
	_a_held           = 0.0
	_b_held           = 0.0
	_score_x_held       = 0.0
	_score_y_held       = 0.0
	_score_was_moving   = false
	_score_trigger_was_held = false
	_label_toggle_held = 0.0
	_restore_pos_frame = 2   # 2フレーム後にカメラ相対で保存位置を復元
	_refresh_label()

func _on_session_ended() -> void:
	$CanvasLayer.visible = true
	get_viewport().transparent_bg = false
	get_viewport().use_xr = false
	($XROrigin3D/ARLabel as Label3D).visible = false

func _on_session_failed(_session_mode: String, message: String) -> void:
	get_viewport().use_xr = false
	$CanvasLayer/MidiLabel.text = "AR FAILED: " + message

func _on_button_pressed() -> void:
	if webxr_interface:
		get_viewport().use_xr = true
		webxr_interface.initialize()

func _on_midi_reset_pressed() -> void:
	MidiReceiver.reset_midi()
	$CanvasLayer/MidiLabel.text = "MIDI: resetting..."


# ── MIDI ──────────────────────────────────────────────────────────────────
func _on_midi_status(text: String) -> void:
	$CanvasLayer/MidiLabel.text = "MIDI: " + text

func _on_note_received(status: int, note: int, velocity: int) -> void:
	var is_on  := (status & 0xF0) == 0x90 and velocity > 0
	var is_off := (status & 0xF0) == 0x80 or ((status & 0xF0) == 0x90 and velocity == 0)
	if is_on:
		($Keyboard as Node3D).note_on(note)
		$CanvasLayer/MidiLabel.text = "NoteOn  note=%d  vel=%d" % [note, velocity]
	elif is_off:
		($Keyboard as Node3D).note_off(note)
		$CanvasLayer/MidiLabel.text = "NoteOff note=%d" % [note]
