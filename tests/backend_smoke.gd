extends SceneTree
# ============================================================
# backend_smoke.gd — 后端冒烟测试（参照对照）
#
# 验证 PhigrosChart 转换器 + Sync 引擎采样与重构前的 line.gd 算法等价：
#   - 音符 hit_time_ms == tick × 1.875/bpm
#   - 判定线 position/rotation/alpha == 旧事件插值结果
#   - 音符 y == (floorPosition − 线累计floor_position) × above × speed_mult × 324
# 期望值由 tests/reference/reference_phigros.py 独立生成（Python，不复用 GDScript 逻辑）。
#
# 用法：
#   godot --headless --path . -s res://tests/backend_smoke.gd
#   godot --headless --path . -s res://tests/backend_smoke.gd -- --chart=<任意官谱.json>
# ============================================================

const FIXTURE_CHART := "res://tests/fixtures/mini_chart.json"
const FIXTURE_EXPECTED := "res://tests/fixtures/mini_expected.json"

# -s 脚本模式不注册全局 class_name，显式 preload 转换器
const PhigrosChart := preload("res://chart/phigros_chart.gd")

const TOL_POS := 1e-2     # 线位置像素容差
const TOL_ROT := 1e-2     # 旋转角度容差
const TOL_ALPHA := 1e-3   # 透明度容差
const TOL_Y := 1e-2       # 音符 y 像素容差
const TOL_MS := 1e-2      # 时间（ms）容差
const PIX_PER_Y := 324.0

var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var user_args := OS.get_cmdline_user_args()
	var chart_path := FIXTURE_CHART
	var expected_path := FIXTURE_EXPECTED
	for arg in user_args:
		if arg.begins_with("--chart="):
			chart_path = arg.trim_prefix("--chart=")
		elif arg.begins_with("--expected="):
			expected_path = arg.trim_prefix("--expected=")

	print("=== backend_smoke: %s ===" % chart_path)

	var raw = JSON.parse_string(FileAccess.get_file_as_string(chart_path))
	if raw == null or not raw is Dictionary:
		_fail("无法解析谱面 %s" % chart_path)
		quit(1)
		return

	var doc: SyncDocumentChart = PhigrosChart.to_document(raw)
	var player := SyncChartPlayer.new()
	root.add_child(player)
	player.set_document_chart(doc)
	var pc: SyncChart = player.get_play_chart()

	var expected = JSON.parse_string(FileAccess.get_file_as_string(expected_path))
	if expected == null:
		_fail("无法读取期望值 %s（先运行 reference_phigros.py 生成）" % expected_path)
		quit(1)
		return

	# --- 谱面结构 ---
	var fmt_ver := int(raw.get("formatVersion", 3))
	var line_count := int(raw.get("judgeLineList", []).size())
	_expect(pc.get_track_count() == line_count,
		"track 数 = %d（期望 %d）" % [pc.get_track_count(), line_count])
	_expect(abs(doc.bpm - float(raw.get("judgeLineList", [])[0].get("bpm", 120.0))) < 1e-9,
		"chart.bpm 取首线 bpm")
	_expect(abs(pc.get_offset_ms() - float(raw.get("offset", 0.0))) < 1e-9,
		"offset_ms = %s" % raw.get("offset", 0.0))

	# --- 逐线对照 ---
	var times: Array = expected["times_ms"]
	for li in expected["lines"].size():
		var track_id := "line_%d" % li
		var ref_line: Dictionary = expected["lines"][li]

		# 音符索引映射：编译后按 hit_time 排序 → 用 metadata.src_index 对应回原始序
		var src_to_id := {}
		for note_id in pc.get_note_ids_for_track(track_id):
			var info: Dictionary = pc.get_note_info(note_id)
			src_to_id[int(info.metadata.get("src_index", -1))] = note_id

		# 音符时间与元数据
		for ref_note: Dictionary in ref_line["notes"]:
			var src := int(ref_note["src_index"])
			var note_id: String = src_to_id.get(src, "")
			if note_id == "":
				_fail("line_%d: 找不到 src_index=%d 的编译音符" % [li, src])
				continue
			var info: Dictionary = pc.get_note_info(note_id)
			_compare("line_%d note[%d].hit_time_ms" % [li, src],
				info.hit_time_ms, float(ref_note["hit_time_ms"]), TOL_MS)
			var expect_kind := 1 if int(ref_note["type"]) == 3 else 0
			_expect(info.kind == expect_kind,
				"line_%d note[%d].kind = %d（期望 %d）" % [li, src, info.kind, expect_kind])
			_expect(abs(float(info.metadata.get("speed", -1.0)) - float(ref_note["speed"])) < 1e-9,
				"line_%d note[%d].speed 透传" % [li, src])
			_expect(int(info.metadata.get("above", 0)) == int(ref_note["above"]),
				"line_%d note[%d].above 透传" % [li, src])

		# 逐时间点采样对照
		for pt: Dictionary in ref_line["per_time"]:
			var t := float(pt["t_ms"])
			var pos: Vector2 = pc.sample_track_vector2_axis(track_id, "position", t)
			_compare("line_%d t=%.0f pos.x" % [li, t], pos.x, float(pt["mx"]), TOL_POS)
			_compare("line_%d t=%.0f pos.y" % [li, t], pos.y, float(pt["my"]), TOL_POS)
			var rot: float = pc.sample_track_float_axis(track_id, "rotation", t)
			_compare("line_%d t=%.0f rot" % [li, t], rot, float(pt["rot"]), TOL_ROT)
			var alpha: float = pc.sample_track_float_axis(track_id, "alpha", t)
			_compare("line_%d t=%.0f alpha" % [li, t], alpha, float(pt["alpha"]), TOL_ALPHA)

			# 音符 y（与旧公式 y=(floorPosition−line_fp)×above×speed_mult×324 等价）
			var ref_y: Array = pt["note_y"]
			for src in ref_y.size():
				var note_id: String = src_to_id.get(src, "")
				if note_id == "":
					continue
				var info: Dictionary = pc.get_note_info(note_id)
				var pos_arr: Array = pc.get_note_normalized_position(note_id, t)
				var above := float(info.metadata.get("above", -1))
				var speed_mult := float(info.metadata.get("speed", 1.0))
				if int(info.metadata.get("phigros_type", 1)) == 3:
					speed_mult = 1.0
				var y := float(pos_arr[0]) * above * speed_mult * PIX_PER_Y
				_compare("line_%d t=%.0f note[%d].y" % [li, t, src],
					y, float(ref_y[src]), TOL_Y)

	print("=== 检查数: %d, 失败: %d ===" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _compare(label: String, got: float, want: float, tol: float) -> void:
	checks += 1
	if not is_equal_approx(got, want) and abs(got - want) > tol:
		failures += 1
		print("FAIL  %s: got %.6f, want %.6f (Δ=%.6f)" % [label, got, want, abs(got - want)])


func _expect(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  %s" % label)


func _fail(label: String) -> void:
	failures += 1
	print("FAIL  %s" % label)
