extends Node3D

# ── MusicXML ファイルパス ─────────────────────────────────────────────────
const SCORE_PATH : String = "res://assets/scores/sample.musicxml"

# ── 五線譜の寸法定数 (m) ──────────────────────────────────────────────────
const LINE_SPACING    : float = 0.012   # 隣接する譜線の間隔
const LINE_THICKNESS  : float = 0.0008
const SIDE_PAD        : float = 0.04    # 譜表の左右余白

const NOTE_SPACING    : float = 0.045   # 四分音符1つ分の水平間隔
const NOTEHEAD_R      : float = 0.0055  # 符頭の半径
const MEASURE_GAP     : float = 0.025   # 小節線の左右に追加する間隔
const LEDGER_LEN      : float = 0.020   # 加線の長さ

# 音名 → 音階インデックス (C=0 ... B=6)
const STEP_INDEX := {"C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6}

# 基準: ト音記号の第一線 (一番下の線) = E4
const REF_DIATONIC : int = 4 * 7 + 2

# localStorage 保存キー (フォーマット: x,y,z,ry,scale — bounded-floor 絶対座標)
# Score は _content 子ノードに描画内容を逃がしてあるため、self の原点が
# そのまま「視覚的な中心」になる → 鍵盤のような half_width 補正は不要。
const SAVE_KEY : String = "score_v1"

var _divisions : int = 1
var _content   : Node3D  # 描画内容を入れる子ノード (中央揃えオフセットはここに適用する)

# main.gd の AR ラベルから参照するデバッグ用ステータス文字列
var debug_status : String = "init"


func _ready() -> void:
	var measures := _load_musicxml(SCORE_PATH)
	if measures.is_empty():
		debug_status = "ERR: 楽譜データが空 (ファイルが開けない or パース失敗)"
		push_warning("score_display: 楽譜データが空です")
		return
	_build_score(measures)
	var n_notes := 0
	for m in measures:
		n_notes += m.size()
	debug_status = "OK 小節=%d 音符=%d 子要素=%d" % [measures.size(), n_notes, _content.get_child_count()]


# ── MusicXML パース ───────────────────────────────────────────────────────
# 必要最小限の情報だけ抽出する簡易パーサ:
#   measures: Array[Array[Dictionary]]
#   各音符: { step, octave, duration, type, is_rest }
func _load_musicxml(path: String) -> Array:
	var measures : Array = []
	var parser := XMLParser.new()
	if parser.open(path) != OK:
		push_warning("score_display: MusicXML が開けません: " + path)
		return measures

	var current_measure : Array = []
	var note_data : Dictionary = {}
	var in_note  := false
	var cur_tag  := ""

	while parser.read() == OK:
		var nt := parser.get_node_type()

		if nt == XMLParser.NODE_ELEMENT:
			var name := parser.get_node_name()
			cur_tag = name
			if name == "measure":
				current_measure = []
			elif name == "note":
				in_note = true
				note_data = {
					"step": "", "octave": 4, "duration": _divisions,
					"type": "quarter", "is_rest": false
				}
			elif name == "rest" and in_note:
				note_data["is_rest"] = true

		elif nt == XMLParser.NODE_TEXT:
			var text := parser.get_node_data().strip_edges()
			if text == "":
				continue
			if cur_tag == "divisions":
				_divisions = int(text)
			elif in_note:
				match cur_tag:
					"step":     note_data["step"]     = text
					"octave":   note_data["octave"]   = int(text)
					"duration": note_data["duration"] = int(text)
					"type":     note_data["type"]     = text

		elif nt == XMLParser.NODE_ELEMENT_END:
			var name := parser.get_node_name()
			if name == "note":
				current_measure.append(note_data.duplicate())
				in_note = false
			elif name == "measure":
				measures.append(current_measure.duplicate())

	return measures


# ── 楽譜の生成 (五線 + 符頭 + 小節線の簡易描画) ────────────────────────────
func _build_score(measures: Array) -> void:
	# 描画内容は _content にまとめる。中央揃えのオフセットは _content の
	# ローカル位置に適用し、Score 自身 (self) の位置・回転は外部 (main.gd) が
	# 鍵盤を基準に自由に制御できるようにする。
	_content = Node3D.new()
	add_child(_content)

	# 全体の幅を見積もる
	var total_units : float = 0.0
	for measure in measures:
		for note in measure:
			total_units += float(note["duration"]) / float(_divisions)
	var n_measures := measures.size()
	var width : float = total_units * NOTE_SPACING \
			+ float(max(n_measures - 1, 0)) * MEASURE_GAP \
			+ SIDE_PAD * 2.0

	# 五線
	for i in range(5):
		_add_line(i * LINE_SPACING, width)

	# 音符・小節線を左から順に配置
	var x : float = SIDE_PAD
	for mi in range(measures.size()):
		if mi > 0:
			_add_barline(x)
			x += MEASURE_GAP
		for note in measures[mi]:
			var dur_q : float = float(note["duration"]) / float(_divisions)
			if not bool(note.get("is_rest", false)) and String(note.get("step", "")) != "":
				_add_notehead(x, String(note["step"]), int(note["octave"]))
			x += dur_q * NOTE_SPACING

	# 全体を中央揃え (五線の中央 = 第三線、横方向も中央)
	# → self ではなく _content 側のローカル位置をずらす
	#   (こうすると視覚的な中心が常に self の原点 = global_position に一致する)
	_content.position.x -= width * 0.5
	_content.position.y -= LINE_SPACING * 2.0


# 音名・オクターブ → 譜表上の縦位置 (m)。第一線 (E4) が 0。
func _staff_y(step: String, octave: int) -> float:
	var idx : int = octave * 7 + int(STEP_INDEX.get(step, 0))
	return float(idx - REF_DIATONIC) * 0.5 * LINE_SPACING


func _add_line(y: float, length: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(length, LINE_THICKNESS, LINE_THICKNESS)
	mi.mesh = bm
	mi.position = Vector3(length * 0.5, y, 0)
	_apply_mat(mi, Color(0.85, 0.85, 0.92), 0.5)
	_content.add_child(mi)


func _add_barline(x: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(LINE_THICKNESS, LINE_SPACING * 4.0 + 0.004, LINE_THICKNESS)
	mi.mesh = bm
	mi.position = Vector3(x, LINE_SPACING * 2.0, 0)
	_apply_mat(mi, Color(0.85, 0.85, 0.92), 0.5)
	_content.add_child(mi)


func _add_notehead(x: float, step: String, octave: int) -> void:
	var y := _staff_y(step, octave)

	# 五線の範囲外なら加線を描く
	var top_line    : float = LINE_SPACING * 4.0
	var bottom_line : float = 0.0
	if y > top_line + 0.0001:
		var ly : float = top_line + LINE_SPACING
		while ly <= y + 0.0001:
			_add_ledger(x, ly)
			ly += LINE_SPACING
	elif y < bottom_line - 0.0001:
		var ly : float = bottom_line - LINE_SPACING
		while ly >= y - 0.0001:
			_add_ledger(x, ly)
			ly -= LINE_SPACING

	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius          = NOTEHEAD_R
	sm.height          = NOTEHEAD_R * 2.0
	sm.radial_segments = 12
	sm.rings           = 6
	mi.mesh  = sm
	mi.position = Vector3(x, y, 0)
	mi.scale = Vector3(1.0, 1.0, 0.4)   # 平たくして符頭らしい形に
	_apply_mat(mi, Color(0.10, 0.10, 0.15), 0.0)
	_content.add_child(mi)


func _add_ledger(x: float, y: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(LEDGER_LEN, LINE_THICKNESS, LINE_THICKNESS)
	mi.mesh = bm
	mi.position = Vector3(x, y, 0)
	_apply_mat(mi, Color(0.85, 0.85, 0.92), 0.5)
	_content.add_child(mi)


# ── 位置保存 (bounded-floor 絶対座標) ─────────────────────────────────────
# Score の原点 = 視覚的な中心なので、global_position をそのまま中心として保存する
# (鍵盤のような half_width 補正は不要)。フォーマット (score_v1): x, y, z, ry, scale
func save_position() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval(
		"localStorage.setItem('%s','%f,%f,%f,%f,%f')" %
		[SAVE_KEY, global_position.x, global_position.y, global_position.z, rotation.y, scale.x]
	)


# ── 位置復元 (bounded-floor 絶対座標から) ─────────────────────────────────
# 戻り値: 保存データを読み込めて復元できたら true / データが無ければ false
# (false の場合、呼び出し側は鍵盤基準の相対配置にフォールバックする)
func load_position_absolute() -> bool:
	if not OS.has_feature("web"):
		return false
	var raw = JavaScriptBridge.eval(
		"(function(){ return localStorage.getItem('%s') || ''; })()" % SAVE_KEY
	)
	if raw == null or str(raw) == "":
		return false
	var parts := str(raw).split(",")
	if parts.size() < 5:
		return false

	var x  : float = float(parts[0])
	var y  : float = float(parts[1])
	var z  : float = float(parts[2])
	var ry : float = float(parts[3])
	var s  : float = float(parts[4])

	# 異常値チェック (壊れたデータで楽譜が消えるのを防ぐ)
	if abs(x) > 20.0 or abs(z) > 20.0 \
			or y < 0.0 or y > 3.0 \
			or s < 0.1 or s > 10.0:
		return false

	global_position = Vector3(x, y, z)
	rotation.y = ry
	scale      = Vector3.ONE * s
	return true


func _apply_mat(mi: MeshInstance3D, color: Color, emission_mult: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if emission_mult > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission_mult
	mi.material_override = mat
