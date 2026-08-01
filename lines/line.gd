extends Node2D
# ============================================================
# line.gd — 判定线（渲染层）
#
# 后端计算全部由 Sync 引擎（SyncChart）承担：
#   - position / rotation / alpha：SyncChart 轴采样
#   - 音符位置：get_note_normalized_position()（速度轴积分）
#
# 音符节点生命周期采用「批量可见查询 + 时间兜底 + SyncNodePool」：
#   - Phigros 官谱音符没有"永久渲染"标签，表演谱存在 speed=9999 瞬移/传送段，
#     音符可能提前数秒~百余秒出现在屏幕上等待（996 谱实测 73/996 音符在 hit 前
#     >5s 已进入屏幕范围），纯时间窗口必然钳制它们
#   - acquire 集合 = Sync 批量可见集 ∪ 时间兜底：
#       可见集：world 每帧一次 get_visible_note_ids（C++ 内循环，GDScript 侧
#         无逐音符调用边界；实测 2330 音符批量 0.005ms vs 逐音符 1.6ms），
#         归一化位置在 [-1,1] 内的音符即渲染，与 hit 时间无关（覆盖表演等待音符）
#       时间兜底：hit 前 FALLBACK_MS 内（get_note_ids_in_time_window，C++ 二分），
#         覆盖 speed=9999 一帧穿越窗口、批量查询 cursor 漏检的情况
#   - 判定先行、释放后置（避免 hit/end 帧被释放逻辑抢先回收而漏判）；
#     release：判定完成（HOLD 按住阶段保持激活），或离开窗口
#   屏幕外音符不渲染、不参与每帧计算：节点数 ≈ 屏幕内音符数，而非谱面总量。
# ============================================================

var window_size = Vector2(960, 540)
var pix_per_X = window_size.x * 0.05625   # = 54 px/单位（positionX -4.2~4.2）
var pix_per_Y = window_size.y * 0.6       # = 324 px/单位（floorPosition → 像素）

const ABOVE := -1
const BELOW := 1
# 时间兜底：hit 前 FALLBACK_MS 内补漏（瞬移穿越窗口、批量可见查询漏检时；
# 同时作为普通音符的提前量——hit 前 1.5s 即实例化，呈现完整飞行过程）
const FALLBACK_MS := 1500.0

var world                    # world 节点引用（判定/特效回调），由 world 注入
var chart: SyncChart         # 编译后的谱面，由 world 注入
var track_id: String         # 对应 Sync 轨道 id（"line_N"），由 world 注入
var line_bpm := 140.0        # 本线 bpm（hold 跟随特效节流用）
var multihit_map := {}       # note_id → 是否多押，由 world 注入

var pool: SyncNodePool       # 音符节点池（绑定 notes.tscn），空闲节点隐藏
var active_notes := {}       # note_id → 活跃音符节点（可见窗口内）

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


# 每帧：采样线动画 + 批量可见查询驱动的音符池
# visible_global 为 world 每帧一次 get_visible_note_ids 的全局可见集（跨线共享）
func update_simulation(chart_ms: float, visible_global: Array) -> void:
	# 线动画采样（后端数据 → 渲染节点）
	position = chart.sample_track_vector2_axis(track_id, "position", chart_ms)
	rotation = deg_to_rad(-chart.sample_track_float_axis(track_id, "rotation", chart_ms))
	$shape.modulate.a = chart.sample_track_float_axis(track_id, "alpha", chart_ms)

	# 应活跃集合 = 本线可见（Sync 批量） ∪ 时间兜底
	var prefix := track_id + ":"
	var in_window := {}
	for note_id in visible_global:
		if String(note_id).begins_with(prefix):
			in_window[note_id] = true
	for note_id in chart.get_note_ids_in_time_window(track_id, chart_ms, chart_ms + FALLBACK_MS):
		if not in_window.has(note_id):
			in_window[note_id] = true

	# 1. 驱动（判定先行）：音符在 hit/end 帧先完成判定，
	#    避免被下方释放逻辑抢先回收而漏判
	for n in active_notes.values():
		n.update_simulation(chart_ms)

	# 2. 释放：判定完成（HOLD 按住阶段保持激活），或离开窗口
	for note_id in active_notes.keys():
		var n = active_notes[note_id]
		if n.judged:
			_release_note(n)
			active_notes.erase(note_id)
		elif not in_window.has(note_id):
			# HOLD 已进入按住阶段（hit 后、end 前）：body 贴线渲染，等待尾判
			if n.note_type == 3 and chart_ms >= float(n.info.hit_time_ms) \
					and chart_ms < float(n.info.end_time_ms):
				continue
			_release_note(n)
			active_notes.erase(note_id)

	# 3. 获取：窗口内但尚未实例化的音符从池中取并绑定数据
	for note_id in in_window:
		if not active_notes.has(note_id):
			_acquire_note(note_id, chart_ms)


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
