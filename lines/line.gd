extends Node2D
# ============================================================
# line.gd — 判定线（渲染层）
#
# 后端计算全部由 Sync 引擎（SyncChart）承担：
#   - position / rotation / alpha：SyncChart 轴采样
#   - 音符位置：get_note_normalized_position()（速度轴积分）
#
# 音符节点生命周期采用「时间窗口驱动 + SyncNodePool」：
#   - Phigros 谱面存在 speed=9999 的瞬移/传送段，音符位置会一帧内跳变
#     穿越整个可视窗口，基于位置的可见性判定会漏检这类音符。
#     Sync 0.6.0 的 get_note_ids_in_time_window 按 hit 时间二分查询，
#     天然免疫速度跳变，本层直接用该 API 驱动节点池：
#   - acquire：hit_time ∈ [chart_ms, chart_ms + LEAD_MS] 的音符，
#     保证音符在命中判定线前 LEAD_MS 即实例化、完整呈现飞行过程
#   - release：判定完成（judged）后释放回池
#   屏幕外音符不实例化、不参与每帧计算：节点数 ≈ 时间窗口内音符数，而非谱面总量。
# ============================================================

var window_size = Vector2(960, 540)
var pix_per_X = window_size.x * 0.05625   # = 54 px/单位（positionX -4.2~4.2）
var pix_per_Y = window_size.y * 0.6       # = 324 px/单位（floorPosition → 像素）

const ABOVE := -1
const BELOW := 1
# 提前量：音符命中判定线前 LEAD_MS 即实例化（Phigros 音符通常提前 1~2 秒可见）
const LEAD_MS := 1500.0

var world                    # world 节点引用（判定/特效回调），由 world 注入
var chart: SyncChart         # 编译后的谱面，由 world 注入
var track_id: String         # 对应 Sync 轨道 id（"line_N"），由 world 注入
var line_bpm := 140.0        # 本线 bpm（hold 跟随特效节流用）
var multihit_map := {}       # note_id → 是否多押，由 world 注入

var pool: SyncNodePool       # 音符节点池（绑定 notes.tscn），空闲节点隐藏
var active_notes := {}       # note_id → 活跃音符节点（时间窗口内）

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

	# 初始化音符节点池（SyncNodePool 继承 Node，无 visible 属性；
	# 空闲节点隐藏由 notes.gd reset_for_pool() 的 visible=false 保证）。
	# prewarm 按谱面规模自适应，避免小谱过度预池化。
	pool = SyncNodePool.new()
	pool.name = "note_pool"
	add_child(pool)
	pool.bind_scene(notes_scene)
	pool.prewarm(clampi(chart.get_note_ids_for_track(track_id).size() / 40, 2, 16))


# 每帧：采样线动画 + 时间窗口驱动的音符池（acquire/释放/位置/判定）
func update_simulation(chart_ms: float) -> void:
	# 线动画采样（后端数据 → 渲染节点）
	position = chart.sample_track_vector2_axis(track_id, "position", chart_ms)
	rotation = deg_to_rad(-chart.sample_track_float_axis(track_id, "rotation", chart_ms))
	$shape.modulate.a = chart.sample_track_float_axis(track_id, "alpha", chart_ms)

	# 时间窗口内将命中的音符（Sync 0.6.0 按 hit 时间二分，免疫 speed 瞬移）
	var pending: Array = chart.get_note_ids_in_time_window(track_id, chart_ms, chart_ms + LEAD_MS)

	# 1. 释放：判定完成的音符恢复初始形态并还回池
	#    （防御：异常未判定且已过 end_time 的音符也释放，避免节点滞留）
	for note_id in active_notes.keys():
		var n = active_notes[note_id]
		if n.judged or chart_ms > float(n.info.end_time_ms) + 200.0:
			_release_note(n)
			active_notes.erase(note_id)

	# 2. 获取：窗口内音符从池中取并绑定数据
	for note_id in pending:
		if not active_notes.has(note_id):
			_acquire_note(note_id, chart_ms)

	# 3. 驱动全部活跃音符（位置 / 判定）
	for n in active_notes.values():
		n.update_simulation(chart_ms)


func _acquire_note(note_id: String, chart_ms: float) -> void:
	var info: Dictionary = chart.get_note_info(note_id)
	# 已完成判定（TAP: end==hit；HOLD: 尾部已到判定线）不再实例化
	if chart_ms >= float(info.end_time_ms):
		return
	var n = pool.acquire()
	if n == null:
		push_warning("line %s: SyncNodePool 未绑定场景或获取失败" % track_id)
		return
	n.bind(note_id, info, self)
	$notes_container.add_child(n)
	n.finish_bind()   # 入树后补设 hold 初始长度（若为 hold 类型）
	active_notes[note_id] = n


func _release_note(n: Node) -> void:
	n.reset_for_pool()
	pool.release(n)   # SyncNodePool 会自动把节点移回池下


# ============================================================
# 角度转弧度 — Phigros → Godot
# Phigros: 角度正值 = 逆时针，Godot: rotation 正值 = 顺时针
# 因此需要取负再转弧度：godot_radians = deg_to_rad(-angle_degrees)
# ============================================================
func deg2rad(angle: float) -> float:
	return deg_to_rad(-angle)
