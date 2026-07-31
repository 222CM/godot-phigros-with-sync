extends Node2D
# ============================================================
# notes.gd — 通用音符节点脚本
# 一个场景文件（notes.tscn），四种音符共用：
#   - Tap(1) / Drag(2) / Flick(4)：切换 $normal_note 的贴图即可
#   - Hold(3)：移除 $normal_note，动态实例化 hold.tscn 作为子节点
# 通过 set_type() 方法设置音符类型和是否多押高亮。
#
# 后端计算由 Sync 引擎承担：每帧 update_simulation(chart_ms) 从
# SyncChart 取归一化位置换算屏幕 y；判定（autoplay）按 hit/end 时间。
# ============================================================

var note_type: int        # 当前音符类型：tap 1 / drag 2 / hold 3 / flick 4

# ============================================================
# 纹理资源预加载
# 普通版 + 多押高亮版（_mh = multi-highlight）
# ============================================================
var tap_tex = preload("res://note_resource/click.png")
var hold_tex = preload("res://note_resource/hold.png")
var drag_tex = preload("res://note_resource/drag.png")
var flick_tex = preload("res://note_resource/flick.png")

var tap_mh_tex = preload("res://note_resource/click_mh.png")
var hold_mh_tex = preload("res://note_resource/hold_mh.png")
var drag_mh_tex = preload("res://note_resource/drag_mh.png")
var flick_mh_tex = preload("res://note_resource/flick_mh.png")

# Hold 场景预加载（Hold 结构较复杂，独立为一个场景）
var hold_scene = preload("res://notes/hold.tscn")
var hold           # 实例化后的 Hold 节点引用

# Sync 数据（由 line.spawn_notes 注入）
var note_id: String        # 编译谱面中的 note id（logic_id）
var info: Dictionary       # SyncChart.get_note_info 缓存（hit/end ms、metadata）
var line                  # 所属判定线（取 chart / pix 换算 / 判定回调）
var judged := false        # 已被判定（line 每帧检查并回收）

var last_hitfx_ms := -INF  # hold 跟随特效节流（毫秒）


# ============================================================
# setup — 注入 Sync 数据（在 add_child 之前调用）
# ============================================================
func setup(p_note_id: String, p_info: Dictionary, p_line) -> void:
	note_id = p_note_id
	info = p_info
	line = p_line


# ============================================================
# set_type — 设置音符类型
# set_note_type: 1=tap 2=drag 3=hold 4=flick
# mh: 是否多押高亮（Multi-Highlight），true = 使用 _mh 纹理
# ============================================================
func set_type(set_note_type: int, mh: bool):
	note_type = set_note_type
	match set_note_type:
		1:
			$normal_note.texture = tap_mh_tex if mh else tap_tex
		2:
			$normal_note.texture = drag_mh_tex if mh else drag_tex
		4:
			$normal_note.texture = flick_mh_tex if mh else flick_tex
		3:
			# Hold 特殊处理：移除普通方块，换为 hold.tscn 实例
			$normal_note.queue_free()
			var h = hold_scene.instantiate()
			h.mh = mh
			add_child(h)
			hold = h


func _ready() -> void:
	scale = Vector2(0.12, 0.12)     # 注意：缩放到合适大小


func _process(delta: float) -> void:
	pass


# ============================================================
# update_simulation — 每帧后端驱动
# y = 归一化头位置 × above × speed_mult × pix_per_Y
#   （归一化位置 = ∫_{chart}^{hit} v dt，等价于原 floorPosition − 线累计 floor_position）
# hold 的 speed 折进长度，位置乘 1（与原实现一致）
# ============================================================
func update_simulation(chart_ms: float) -> void:
	if judged:
		return

	var pos: Array = line.chart.get_note_normalized_position(note_id, chart_ms)
	var above := float(info.metadata.get("above", -1))
	var speed_mult := float(info.metadata.get("speed", 1.0))
	if int(info.metadata.get("phigros_type", 1)) == 3:
		speed_mult = 1.0
	position.y = float(pos[0]) * above * speed_mult * line.pix_per_Y

	if int(info.metadata.get("phigros_type", 1)) == 3:
		_update_hold(chart_ms)
	elif chart_ms >= info.hit_time_ms:
		_judge()


# hold 专用：头判（隐藏头部+贴线+缩短）→ 尾判（计分+销毁）
func _update_hold(chart_ms: float) -> void:
	if chart_ms >= info.end_time_ms:
		_judge()
		return

	if chart_ms >= info.hit_time_ms:
		hold.set_hide_start(true)
		position.y = 0
		var remain_ms: float = float(info.end_time_ms) - chart_ms
		hold.set_length(remain_ms / 1000.0 * float(info.metadata.get("speed", 1.0)) * line.pix_per_Y / 0.12)

		# 跟随特效：每 30/bpm 秒一次（与原实现一致）
		if chart_ms >= last_hitfx_ms + 30000.0 / line.line_bpm:
			line.world.spawn_hit_effect(global_position)
			last_hitfx_ms = chart_ms


# autoplay 判定：计分 + 特效（tap/drag/flick）+ 销毁
func _judge() -> void:
	if judged:
		return
	judged = true

	if int(info.metadata.get("phigros_type", 1)) != 3:
		position.y = 0
		line.world.spawn_hit_effect(global_position)
	line.world.on_note_judged()

	visible = false
	queue_free()
