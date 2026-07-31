extends Node2D
# ============================================================
# line.gd — 判定线（渲染层）
#
# 后端计算全部由 Sync 引擎（SyncChart）承担：
#   - position / rotation / alpha：SyncChart 轴采样
#   - 音符位置：get_note_normalized_position()（速度轴积分）
# 本脚本只负责把采样结果应用到渲染节点，并转发判定/特效回调。
# ============================================================

var window_size = Vector2(960, 540)
var pix_per_X = window_size.x * 0.05625   # = 54 px/单位（positionX -4.2~4.2）
var pix_per_Y = window_size.y * 0.6       # = 324 px/单位（floorPosition → 像素）

const ABOVE = -1
const BELOW = 1

var world                    # world 节点引用（判定/特效回调），由 world 注入
var chart: SyncChart         # 编译后的谱面，由 world 注入
var track_id: String         # 对应 Sync 轨道 id（"line_N"），由 world 注入
var line_bpm := 140.0        # 本线 bpm（hold 跟随特效节流用）
var multihit_map := {}       # note_id → 是否多押，由 world 注入

var notes = []               # 音符渲染节点（notes.gd 实例）
var notes_scene = preload("res://notes/notes.tscn")


func setup(p_world: Node, p_track_id: String, p_chart: SyncChart, p_multihit: Dictionary) -> void:
	world = p_world
	track_id = p_track_id
	chart = p_chart
	multihit_map = p_multihit


func _ready() -> void:
	# 初始化线的形状
	$shape.size = Vector2(window_size.x * 3, 4.1)
	$shape.position = (Vector2(0, 0) - $shape.size) / 2

	line_bpm = float(chart.get_track_info(track_id).get("metadata", {}).get("bpm", 140.0))
	spawn_notes()


# 一次性生成该线全部音符节点（数据全部来自编译后的 SyncChart）
func spawn_notes() -> void:
	for note_id in chart.get_note_ids_for_track(track_id):
		var info: Dictionary = chart.get_note_info(note_id)
		var n = notes_scene.instantiate()
		n.setup(note_id, info, self)
		notes.append(n)
		$notes_container.add_child(n)

		n.position.x = float(info.metadata.get("position_x", 0.0)) * pix_per_X
		n.set_type(int(info.metadata.get("phigros_type", 1)), bool(multihit_map.get(note_id, false)))

		# 反向（below）音符整体翻转
		if int(info.metadata.get("above", ABOVE)) == BELOW:
			n.rotation = deg2rad(180)

		# hold 初始长度（与原公式一致）：(end−hit)ms → 秒 × speed × px/Y ÷ 缩放
		if info.kind == 1:
			var hold_len = (info.end_time_ms - info.hit_time_ms) / 1000.0 \
				* float(info.metadata.get("speed", 1.0)) * pix_per_Y / 0.12
			n.hold.set_length(hold_len)


# 每帧：采样线动画 + 驱动全部音符
func update_simulation(chart_ms: float) -> void:
	position = chart.sample_track_vector2_axis(track_id, "position", chart_ms)
	rotation = deg_to_rad(-chart.sample_track_float_axis(track_id, "rotation", chart_ms))
	$shape.modulate.a = chart.sample_track_float_axis(track_id, "alpha", chart_ms)

	var to_free := []
	for n in notes:
		n.update_simulation(chart_ms)
		if n.judged:
			to_free.append(n)
	for n in to_free:
		notes.erase(n)


# ============================================================
# 角度转弧度 — Phigros → Godot
# Phigros: 角度正值 = 逆时针，Godot: rotation 正值 = 顺时针
# 因此需要取负再转弧度：godot_radians = deg_to_rad(-angle_degrees)
# ============================================================
func deg2rad(angle: float) -> float:
	return deg_to_rad(-angle)
