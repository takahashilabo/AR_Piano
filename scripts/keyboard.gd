extends Node3D

# ── 位置計算用の寸法定数 (m) ──────────────────────────────────────────────
const WHITE_W : float = 0.023    # 白鍵幅
const WHITE_H : float = 0.015    # 白鍵高さ
const WHITE_D : float = 0.130    # 白鍵奥行き
const BLACK_H : float = 0.025    # 黒鍵高さ
const BLACK_D : float = 0.080    # 黒鍵奥行き

const FIRST_NOTE      : int   = 21     # A0
const LAST_NOTE       : int   = 108    # C8
const BLACK_SEMITONES         = [1, 3, 6, 8, 10]
const N_WHITE         : int   = 52
const HALF_W          : float = 52.0 * 0.023 * 0.5   # 0.598 m

# ── 球のサイズ ──────────────────────────────────────────────────────────
const SR_W : float = 0.0045  # 白鍵球の半径 4.5mm
const SR_B : float = 0.0035  # 黒鍵球の半径 3.5mm

# ── アニメーション定数 ───────────────────────────────────────────────────
const BREATHE_SPEED : float = 1.3    # 呼吸の速さ (rad/s)
const SPARKLE_PROB  : float = 0.003  # スパークル発生確率 / frame / key
const SPARKLE_DUR   : float = 0.35   # スパークル持続時間 (s)
const ACTIVE_SPEED  : float = 14.0   # 演奏中パルス速度 (rad/s)

var _keys    : Dictionary = {}   # note -> MeshInstance3D
var _mats    : Dictionary = {}   # note -> StandardMaterial3D
var _active  : Dictionary = {}   # note -> bool
var _sparkle : Dictionary = {}   # note -> float (スパークル残り時間 s)
var _time    : float = 0.0


func _ready() -> void:
	_build_spheres()


# ── 球の生成 ─────────────────────────────────────────────────────────────
# ピアノ鍵盤のタッチポイントに光る球を配置する。
# 白鍵: 前部タッチゾーン (z = WHITE_D*0.30) のやや上に配置
# 黒鍵: 黒鍵中央 (z = -(WHITE_D-BLACK_D)/2+0.01) の頂部に配置
func _build_spheres() -> void:
	var wi := 0
	for note in range(FIRST_NOTE, LAST_NOTE + 1):
		var sem  : int  = note % 12
		var is_b : bool = sem in BLACK_SEMITONES

		var mi  := MeshInstance3D.new()
		var sm  := SphereMesh.new()
		var mat := StandardMaterial3D.new()
		mat.emission_enabled = true
		sm.radial_segments   = 10
		sm.rings             = 5

		if is_b:
			sm.radius = SR_B
			sm.height = SR_B * 2.0
			mi.position = Vector3(
				(wi - 0.5) * WHITE_W,
				WHITE_H * 0.5 + BLACK_H * 0.5 + SR_B + 0.001,
				-(WHITE_D - BLACK_D) * 0.5 + 0.010
			)
			mat.albedo_color             = Color(0.35, 0.35, 1.0)
			mat.emission                 = Color(0.25, 0.25, 0.90)
			mat.emission_energy_multiplier = 0.8
		else:
			sm.radius = SR_W
			sm.height = SR_W * 2.0
			mi.position = Vector3(
				wi * WHITE_W,
				WHITE_H * 0.5 + SR_W + 0.002,
				WHITE_D * 0.30
			)
			mat.albedo_color             = Color(0.80, 0.75, 1.0)
			mat.emission                 = Color(0.65, 0.60, 1.0)
			mat.emission_energy_multiplier = 1.0
			wi += 1

		mi.mesh              = sm
		mi.material_override = mat
		add_child(mi)
		_keys[note]    = mi
		_mats[note]    = mat
		_active[note]  = false
		_sparkle[note] = 0.0

	# 全体を中央揃え (main.gd の HALF_W 計算と一致)
	position.x -= N_WHITE * WHITE_W * 0.5


# ── アニメーション ────────────────────────────────────────────────────────
# 3 状態:
#   1. 演奏中   : 緑の高速パルス
#   2. スパークル: ランダムな閃光 (白鍵=金色, 黒鍵=青白)
#   3. 待機中   : 位相オフセット付きの呼吸 (左から右へ波のように流れる)
func _process(delta: float) -> void:
	_time += delta

	for note in _keys:
		var mat  : StandardMaterial3D = _mats[note]
		var is_b : bool  = (note % 12) in BLACK_SEMITONES

		if _active[note]:
			# ── 演奏中: 緑の高速パルス ──────────────────────────────────
			var p : float = 0.5 + 0.5 * sin(_time * ACTIVE_SPEED)
			mat.albedo_color               = Color(0.10, 1.00, 0.30)
			mat.emission                   = Color(0.05, 0.90, 0.15)
			mat.emission_energy_multiplier = 4.0 + p * 7.0

		else:
			# スパークルを確率トリガー
			if _sparkle[note] <= 0.0 and randf() < SPARKLE_PROB:
				_sparkle[note] = SPARKLE_DUR * (0.8 + randf() * 0.4)

			if _sparkle[note] > 0.0:
				_sparkle[note] -= delta
				# 山なり (sin カーブ) の閃光
				var t      : float = clamp(1.0 - _sparkle[note] / SPARKLE_DUR, 0.0, 1.0)
				var bright : float = sin(t * PI) * 5.5
				if is_b:
					mat.albedo_color = Color(0.65, 0.65, 1.00)
					mat.emission     = Color(0.50, 0.50, 1.00)
				else:
					mat.albedo_color = Color(1.00, 0.95, 0.70)
					mat.emission     = Color(1.00, 0.88, 0.45)
				mat.emission_energy_multiplier = 1.5 + bright
			else:
				# ── 待機中: 一様な呼吸 ──────────────────────────────────
				var breath : float = 0.5 + 0.5 * sin(_time * BREATHE_SPEED)
				if is_b:
					mat.albedo_color               = Color(0.35, 0.35, 1.00)
					mat.emission                   = Color(0.25, 0.25, 0.85)
					mat.emission_energy_multiplier = 0.25 + breath * 0.65
				else:
					mat.albedo_color               = Color(0.80, 0.75, 1.00)
					mat.emission                   = Color(0.60, 0.55, 1.00)
					mat.emission_energy_multiplier = 0.35 + breath * 0.75


# ── MIDI ─────────────────────────────────────────────────────────────────
func note_on(note: int) -> void:
	if _active.has(note):
		_active[note] = true

func note_off(note: int) -> void:
	if _active.has(note):
		_active[note] = false


# ── 位置保存 (bounded-floor 絶対座標) ─────────────────────────────────────
# bounded-floor はガーディアン境界に固定された座標系のため
# セッションをまたいでも絶対座標が一致し位置ずれが起きない。
#
# フォーマット (kb_v3): x, y, z, ry, scale
func save_position() -> void:
	if not OS.has_feature("web"):
		return

	var half_w    : float   = HALF_W * scale.x
	var kb_center : Vector3 = global_position + transform.basis.x * half_w

	var x  : float = kb_center.x
	var y  : float = kb_center.y
	var z  : float = kb_center.z
	var ry : float = rotation.y
	var s  : float = scale.x

	JavaScriptBridge.eval(
		"localStorage.setItem('kb_v3','%f,%f,%f,%f,%f')" %
		[x, y, z, ry, s]
	)


# ── 位置復元 (bounded-floor 絶対座標から) ────────────────────────────────
func load_position_absolute() -> void:
	if not OS.has_feature("web"):
		return
	var raw = JavaScriptBridge.eval(
		"(function(){ return localStorage.getItem('kb_v3') || ''; })()"
	)
	if raw == null or str(raw) == "":
		return
	var parts := str(raw).split(",")
	if parts.size() < 5:
		return

	var x  : float = float(parts[0])
	var y  : float = float(parts[1])
	var z  : float = float(parts[2])
	var ry : float = float(parts[3])
	var s  : float = float(parts[4])

	# 異常値チェック (壊れたデータで球が消えるのを防ぐ)
	if abs(x) > 20.0 or abs(z) > 20.0 \
			or y < 0.0 or y > 3.0 \
			or s < 0.1 or s > 10.0:
		return

	rotation.y = ry
	scale      = Vector3.ONE * s

	var kb_center : Vector3 = Vector3(x, y, z)
	var half_w    : float   = HALF_W * s
	global_position = kb_center - transform.basis.x * half_w
