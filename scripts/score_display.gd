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

# ── 小節選択 (ポインティング) 用データ ─────────────────────────────────────
var _measures        : Array = []   # _ready() でパースした小節データを保持
var _measure_ranges  : Array = []   # 各小節の x 範囲 [start, end] (_content ローカル座標系)
var _staff_top       : float = 0.0  # 当たり判定用の y 範囲 (ledger 線の余白込み)
var _staff_bottom    : float = 0.0

var _hover_mi        : int = -1     # ポインティング中の小節 index (-1 = なし)
var _selected_mi     : int = -1     # 確定選択された小節 index (-1 = なし)

var _hover_box       : MeshInstance3D
var _select_box      : MeshInstance3D

const HOVER_COLOR  := Color(1.0, 1.0, 0.4, 0.18)
const SELECT_COLOR := Color(0.3, 1.0, 0.5, 0.30)
const HILITE_H_PAD : float = 0.006   # ハイライト枠の上下方向の余白


func _ready() -> void:
	var measures := _load_musicxml(SCORE_PATH)
	if measures.is_empty():
		debug_status = "ERR: 楽譜データが空 (ファイルが開けない or パース失敗)"
		push_warning("score_display: 楽譜データが空です")
		return
	_measures = measures
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

	# 音符・小節線を左から順に配置 (同時に各小節の x 範囲を記録 → ポインティング判定用)
	_measure_ranges = []
	var x : float = SIDE_PAD
	for mi in range(measures.size()):
		if mi > 0:
			_add_barline(x)
			x += MEASURE_GAP
		var start_x : float = x
		for note in measures[mi]:
			var dur_q : float = float(note["duration"]) / float(_divisions)
			if not bool(note.get("is_rest", false)) and String(note.get("step", "")) != "":
				_add_notehead(x, String(note["step"]), int(note["octave"]))
			x += dur_q * NOTE_SPACING
		_measure_ranges.append(Vector2(start_x - MEASURE_GAP * 0.5, x + MEASURE_GAP * 0.5))

	# ポインティング当たり判定用の y 範囲 (五線の上下に余白を持たせる)
	_staff_top    = LINE_SPACING * 4.0 + LINE_SPACING * 2.0
	_staff_bottom = -LINE_SPACING * 2.0

	_build_highlight_boxes(width)

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


# ── 小節ハイライト枠の生成 (ポインティング選択用) ──────────────────────────
# hover (ポインティング中) / select (確定選択) それぞれ 1 個ずつ枠を使い回し、
# 対象小節の x 範囲 + 五線の y 範囲に合わせて移動・リサイズして表示する。
func _build_highlight_boxes(_width: float) -> void:
	_hover_box  = _make_highlight_box(HOVER_COLOR)
	_select_box = _make_highlight_box(SELECT_COLOR)
	_content.add_child(_hover_box)
	_content.add_child(_select_box)


func _make_highlight_box(color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 1.0, LINE_THICKNESS)   # 実サイズは表示時に _place_highlight_box で設定
	mi.mesh = bm

	var mat := StandardMaterial3D.new()
	mat.albedo_color               = color   # alpha は HOVER_COLOR/SELECT_COLOR に含む
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 0.6
	mi.material_override = mat

	mi.position.z = -0.004   # 符頭 (z=0 付近) より奥に置いて重ならないようにする
	mi.visible = false
	return mi


# 指定した小節 index に合わせて枠の位置・サイズを更新する (idx < 0 で非表示)
func _place_highlight_box(box: MeshInstance3D, mi_idx: int) -> void:
	if box == null:
		return
	if mi_idx < 0 or mi_idx >= _measure_ranges.size():
		box.visible = false
		return

	var r : Vector2 = _measure_ranges[mi_idx]
	var w : float = r.y - r.x
	var h : float = (_staff_top - _staff_bottom) + HILITE_H_PAD * 2.0

	var bm : BoxMesh = box.mesh as BoxMesh
	bm.size = Vector3(w, h, LINE_THICKNESS)
	box.position.x = (r.x + r.y) * 0.5
	box.position.y = (_staff_top + _staff_bottom) * 0.5
	box.visible = true


# ポインティング中の小節を更新する (-1 でハイライト解除)
func set_hover_measure(mi_idx: int) -> void:
	if mi_idx == _hover_mi:
		return
	_hover_mi = mi_idx
	_place_highlight_box(_hover_box, _hover_mi)


# 確定選択された小節を更新する (-1 で選択解除)。戻り値: 変更があったら true
func set_selected_measure(mi_idx: int) -> bool:
	if mi_idx == _selected_mi:
		return false
	_selected_mi = mi_idx
	_place_highlight_box(_select_box, _selected_mi)
	return true


func get_selected_measure() -> int:
	return _selected_mi


# 音名 → 半音オフセット (C=0 ... B=11)。MIDI ノート番号への変換に使用。
const STEP_SEMITONE := {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

# 演奏ガイドの基準テンポ: 四分音符 1 つ分の表示秒数
const GLOW_SEC_PER_QUARTER : float = 0.55


# 指定した小節の演奏ガイド・シーケンスを返す (main.gd の鍵盤グローで使用)。
# 各要素は { note: int (MIDI ノート番号、休符なら -1), dur_sec: float } で、
# 演奏順 (MusicXML の記述順) に並んでいる。
func get_measure_playback(mi_idx: int) -> Array:
	var seq : Array = []
	if mi_idx < 0 or mi_idx >= _measures.size():
		return seq

	for note in _measures[mi_idx]:
		var dur_q : float = float(note["duration"]) / float(_divisions)
		var midi  : int = -1
		if not bool(note.get("is_rest", false)) and String(note.get("step", "")) != "":
			var step   : String = String(note["step"])
			var octave : int    = int(note["octave"])
			midi = (octave + 1) * 12 + int(STEP_SEMITONE.get(step, 0))
		seq.append({"note": midi, "dur_sec": dur_q * GLOW_SEC_PER_QUARTER})

	return seq


# ── ポインティングによる小節判定 (レイと譜面平面のジオメトリ交差) ──────────
# world_from: コントローラーのレイ始点 (world space)
# world_dir : レイの方向ベクトル (world space, 正規化不要)
# 戻り値    : ヒットした小節 index (ヒットしなければ -1)
#
# 譜面は _content 配下に z=0 の平面として描画されているため、Godot の物理
# レイキャストではなく、レイをローカル空間に変換して z=0 平面との交点を求め、
# その交点が各小節の x 範囲・五線の y 範囲内にあるかを調べる。
func measure_index_from_ray(world_from: Vector3, world_dir: Vector3) -> int:
	if _content == null or _measure_ranges.is_empty():
		return -1

	var xform      : Transform3D = _content.global_transform.affine_inverse()
	var local_from : Vector3 = xform * world_from
	var local_dir  : Vector3 = (xform.basis * world_dir).normalized()

	# レイがほぼ平面に平行なら交点なし
	if abs(local_dir.z) < 0.000001:
		return -1

	var t : float = -local_from.z / local_dir.z
	if t < 0.0:
		return -1   # 平面が後方にある

	var hit : Vector3 = local_from + local_dir * t

	if hit.y < _staff_bottom - HILITE_H_PAD or hit.y > _staff_top + HILITE_H_PAD:
		return -1

	for i in range(_measure_ranges.size()):
		var r : Vector2 = _measure_ranges[i]
		if hit.x >= r.x and hit.x <= r.y:
			return i

	return -1


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
