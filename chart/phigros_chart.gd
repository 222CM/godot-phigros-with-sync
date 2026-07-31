extends RefCounted
# ============================================================
# phigros_chart.gd — Phigros 官谱 JSON → SyncDocumentChart 转换器
#
# 职责：把 Phigros 谱面 JSON（裸字典）转换为 Sync 引擎的文档谱面，
#       让 Sync 承担全部后端计算（BPM/时间换算、判定线动画采样、
#       音符位置计算）。游戏侧只保留渲染与判定。
#
# 映射关系（一条判定线 = 一个 SyncTrack）：
#   judgeLineMoveEvents      → Vector2 轴 "position"（像素坐标，按 formatVersion 换算）
#   judgeLineRotateEvents    → float 轴 "rotation"（角度原值，游戏侧取负转弧度）
#   judgeLineDisappearEvents → float 轴 "alpha"（0~1）
#   speedEvents              → SyncSpeedAxis "speed"（音符归一化位置的速度积分源）
#   notesAbove/notesBelow    → SyncNote（type 3 → HOLD，其余 → TAP；原始字段存 metadata）
#
# 时间换算：Phigros 谱面时间单位为 tick，1 拍 = 32 tick（隐含 4/4，60/32 = 1.875）。
#   beat = tick × chart_bpm / (32 × line_bpm)
#   均匀 bpm 时即 beat = tick/32；不同线 bpm 不同时按线缩放（近似支持）。
#   SyncBeat 用分母 32000（0.001 tick 精度）表示。
#
# 事件 → 轴关键帧（Sync 轴不排序，必须严格按事件顺序插入）：
#   start==end（常数段）→ 起点 STEP 关键帧（跳变在起点发生，段内保持）
#   start!=end（线性段）→ 起点 LINEAR + 终点 LINEAR 关键帧
#   startTime ≤ 0 的事件按 0 时刻实际值重锚（谱面常见 -999999 起始事件）
# ============================================================

const TRANS_STEP := 0      # SyncTrans.STEP
const TRANS_LINEAR := 1    # SyncTrans.LINEAR
const WINDOW_SIZE := Vector2(960, 540)
const BEAT_SCALE := 32000  # SyncBeat 分母（1/32000 拍 ≈ 0.001 tick 精度）


# 转换入口：Phigros 谱面 JSON 字典 → SyncDocumentChart
static func to_document(raw: Dictionary) -> SyncDocumentChart:
	var doc := SyncDocumentChart.new()
	var format_version := int(raw.get("formatVersion", 3))
	doc.offset_ms = float(raw.get("offset", 0.0))
	doc.spec_name = "Phigros"
	doc.spec_version = str(format_version)
	doc.metadata = {
		"format_version": format_version,
		"source": "Phigros",
	}

	var lines: Array = raw.get("judgeLineList", [])
	if lines.is_empty():
		push_warning("PhigrosChart: judgeLineList 为空")
		return doc

	var chart_bpm := float(lines[0].get("bpm", 120.0))
	doc.bpm = chart_bpm

	for i in lines.size():
		var line_raw: Dictionary = lines[i]
		var line_bpm := float(line_raw.get("bpm", chart_bpm))
		if not is_equal_approx(line_bpm, chart_bpm):
			push_warning("PhigrosChart: judgeLine %d bpm 与首线不同 (%s vs %s)，按线缩放时间" % [i, line_bpm, chart_bpm])

		var track := SyncTrack.new()
		track.track_id = "line_%d" % i
		track.metadata = {"bpm": line_bpm}

		_add_position_axis(track, line_raw.get("judgeLineMoveEvents", []), format_version, line_bpm, chart_bpm)
		_add_float_axis(track, "rotation", line_raw.get("judgeLineRotateEvents", []), 0.0, line_bpm, chart_bpm)
		_add_float_axis(track, "alpha", line_raw.get("judgeLineDisappearEvents", []), 1.0, line_bpm, chart_bpm)
		_add_speed_axis(track, line_raw.get("speedEvents", []), line_bpm, chart_bpm)
		_add_notes(track, line_raw.get("notesAbove", []), line_raw.get("notesBelow", []), line_bpm, chart_bpm)

		doc.add_root_track(track)

	return doc


# ---------- 轴 ----------

static func _add_position_axis(track: SyncTrack, events: Array, format_version: int, line_bpm: float, chart_bpm: float) -> void:
	var axis := SyncVector2Axis.new()
	axis.axis_name = "position"
	axis.init_value = WINDOW_SIZE / 2.0
	for ev in events:
		var start := _move_value_to_px(ev, "start", "start2", format_version)
		var end := _move_value_to_px(ev, "end", "end2", format_version)
		_add_event_keyframes(axis, float(ev.get("startTime", 0.0)), float(ev.get("endTime", 0.0)),
			start, end, line_bpm, chart_bpm)
	track.add_vector2_axis(axis)


static func _add_float_axis(track: SyncTrack, axis_name: String, events: Array, init_value: float, line_bpm: float, chart_bpm: float) -> void:
	var axis := SyncFloatAxis.new()
	axis.axis_name = axis_name
	axis.init_value = init_value
	for ev in events:
		var start := float(ev.get("start", init_value))
		var end := float(ev.get("end", init_value))
		_add_event_keyframes(axis, float(ev.get("startTime", 0.0)), float(ev.get("endTime", 0.0)),
			start, end, line_bpm, chart_bpm)
	track.add_float_axis(axis)


static func _add_speed_axis(track: SyncTrack, events: Array, line_bpm: float, chart_bpm: float) -> void:
	var axis := SyncSpeedAxis.new()
	axis.axis_name = "speed"   # 名字硬编码：PlayTrack 只认 "speed" 参与归一化位置
	axis.init_value = 1.0
	for ev in events:
		axis.add_keyframe(_beat_from_ticks(float(ev.get("startTime", 0.0)), line_bpm, chart_bpm),
			float(ev.get("value", 1.0)), TRANS_STEP)
	track.add_speed_axis(axis)


# 事件 → 关键帧（见文件头注释规则）
static func _add_event_keyframes(axis: Object, start_tick: float, end_tick: float, start_value: Variant, end_value: Variant, line_bpm: float, chart_bpm: float) -> void:
	# 线性段且起点在 0 之前：按 0 时刻的实际插值值重锚（-999999 起始事件）
	if start_tick < 0.0 and start_value != end_value:
		var t0 := (0.0 - start_tick) / (end_tick - start_tick)
		start_value = start_value.lerp(end_value, t0)
		start_tick = 0.0

	if start_value == end_value:
		# 常数段：起点 + 终点各一个 STEP 关键帧。
		# 终点关键帧保证"段内保持、在终点跳变"——否则后续不同值的
		# 关键帧（如 fade 事件）会把本段从起点拉成渐变。
		axis.add_keyframe(_beat_from_ticks(start_tick, line_bpm, chart_bpm), start_value, TRANS_STEP)
		if end_tick > start_tick:
			axis.add_keyframe(_beat_from_ticks(end_tick, line_bpm, chart_bpm), end_value, TRANS_STEP)
	else:
		# 线性段：起点 LINEAR + 终点 LINEAR
		axis.add_keyframe(_beat_from_ticks(start_tick, line_bpm, chart_bpm), start_value, TRANS_LINEAR)
		axis.add_keyframe(_beat_from_ticks(end_tick, line_bpm, chart_bpm), end_value, TRANS_LINEAR)


# move 事件数值 → 像素坐标（与原 line.gd 的 formatVersion 分支一致）
static func _move_value_to_px(ev: Dictionary, v1_key: String, v2_key: String, format_version: int) -> Vector2:
	var a := float(ev.get(v1_key, 0.0))
	var b := float(ev.get(v2_key, 0.0))
	if format_version == 1:
		return Vector2(
			int(a) / 1000.0 / 880.0 * WINDOW_SIZE.x,
			WINDOW_SIZE.y - (int(a) % 1000) / 520.0 * WINDOW_SIZE.y
		)
	elif format_version == 3:
		return Vector2(a * WINDOW_SIZE.x, (1.0 - b) * WINDOW_SIZE.y)
	else:  # formatVersion 2：单位 = 屏幕高 10%，原点在屏幕中心
		var unit := WINDOW_SIZE.y * 0.1
		return Vector2(WINDOW_SIZE.x / 2.0 + a * unit, WINDOW_SIZE.y / 2.0 - b * unit)


# ---------- 音符 ----------

static func _add_notes(track: SyncTrack, above_raw: Array, below_raw: Array, line_bpm: float, chart_bpm: float) -> void:
	var idx := 0
	for raw_note in above_raw:
		idx = _append_note(track, raw_note, -1, idx, line_bpm, chart_bpm)
	for raw_note in below_raw:
		idx = _append_note(track, raw_note, 1, idx, line_bpm, chart_bpm)


static func _append_note(track: SyncTrack, raw_note: Dictionary, above: int, idx: int, line_bpm: float, chart_bpm: float) -> int:
	var note := SyncNote.new()
	note.local_id = "n_%d" % idx
	idx += 1

	var ptype := int(raw_note.get("type", 1))
	var note_tick := float(raw_note.get("time", 0.0))
	note.kind = 1 if ptype == 3 else 0   # HOLD / TAP
	note.time = _beat_from_ticks(note_tick, line_bpm, chart_bpm)
	if note.kind == 1:
		note.end_time = _beat_from_ticks(note_tick + float(raw_note.get("holdTime", 0.0)), line_bpm, chart_bpm)

	note.metadata = {
		"phigros_type": ptype,
		"speed": float(raw_note.get("speed", 1.0)),
		"position_x": float(raw_note.get("positionX", 0.0)),
		"above": above,
		"floor_position": float(raw_note.get("floorPosition", 0.0)),
		"src_index": idx - 1,   # 测试用：线内原始序号
	}
	track.add_note(note)
	return idx


# ---------- 时间 ----------

# tick → SyncBeat（beat = tick × chart_bpm / (32 × line_bpm)）
static func _beat_from_ticks(ticks: float, line_bpm: float, chart_bpm: float) -> SyncBeat:
	var t := maxf(0.0, ticks)   # 负时间（-999999 起始事件）钳到 0
	var beats := t * chart_bpm / (32.0 * line_bpm)
	return SyncBeat.from_array([0, int(round(beats * BEAT_SCALE)), BEAT_SCALE])
