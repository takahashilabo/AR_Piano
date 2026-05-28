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
			_refresh_label()
	var fwd : Vector3 = -cam.global_transform.basis.z.normalized()
	($XROrigin3D/ARLabel as Label3D).global_position = \
		cam.global_position + fwd * 0.8 + Vector3(-0.2, -0.1, 0)

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


# ── AR ラベル ─────────────────────────────────────────────────────────────
func _refresh_label(extra: String = "") -> void:
	var kb  := $Keyboard as Node3D
	var p   : Vector3 = kb.global_position
	var rot : float   = rad_to_deg(kb.rotation.y)
	var scl : float   = kb.scale.x
	var txt := "[Calib]  Trig:移動  A/B:回転  StickY:拡縮  (自動保存)\n"
	txt += "X:%.2f Y:%.2f Z:%.2f\n" % [p.x, p.y, p.z]
	txt += "Rot:%.1f  Scale:%.2f" % [rot, scl]
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
	($XROrigin3D/ARLabel as Label3D).visible = true
	# 前セッションの残りフラグをリセット（誤った自動保存を防ぐ）
	_was_moving       = false
	_trigger_was_held = false
	_a_held           = 0.0
	_b_held           = 0.0
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
