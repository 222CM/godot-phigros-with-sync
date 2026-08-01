extends Node2D
# ============================================================
# notes.gd — 通用音符节点脚本（SyncNodePool 池化复用版）
# 一个场景文件（notes.tscn），四种音符共用：
#   - Tap(1) / Drag(2) / Flick(4)：切换 $normal_note 贴图
#   - Hold(3)：隐藏 $normal_note，动态实例化 hold.tscn 作为子节点
#
# 生命周期由所属判定线（line.gd）驱动：
#   - 音符进入视野 → line 从 SyncNodePool acquire 后调用 bind() 绑定数据
#   - 判定完成/离开视野 → line 调用 reset_for_pool() 恢复初始形态再 release 回池
# 后端计算由 Sync 引擎承担：每帧 update_simulation(chart_ms) 从
# SyncChart 取归一化位置换算屏幕 y；判定（autoplay）按 hit/end 时间。
# ============================================================

var note_type: int = 1        # 当前音符类型：tap 1 / drag 2 / hold 3 / flick 4

# ============================================================
# 纹理资源预加载（普通版 + 多押高亮版 _mh = multi-highlight）
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
var hold            # 实例化后的 Hold 节点引用（仅 hold 类型存在）

# Sync 数据（由 line 在 acquire/bind 时注入）
var note_id: String = ""
var info: Dictionary = {}
var line              # 所属判定线（取 chart / pix 换算 / 判定回调）
var judged := false   # 已被判定（line 每帧检查并释放回池）

var last_hitfx_ms := -INF  # hold 跟随特效节流（毫秒）


func _ready() -> void:
	scale = Vector2(0.12, 0.12)     # 注意：缩放到合适大小
	# 首次从池取出时 bind 在入树前执行，hold 子节点此时才完成初始化，
	# 这里补设 hold 初始长度（子节点先于父节点 _ready，hold 已可用）
	if note_type == 3:
		_apply_hold_length()


# ============================================================
# bind — 从池中取出后绑定一条音符数据（line 在 acquire 后调用）
# ============================================================
func bind(p_note_id: String, p_info: Dictionary, p_line) -> void:
	note_id = p_note_id
	info = p_info
	line = p_line
	judged = false
	visible = true
	position = Vector2.ZERO
	rotation = 0.0
	last_hitfx_ms = -INF

	set_type(int(info.metadata.get("phigros_type", 1)), bool(line.multihit_map.get(note_id, false)))

	# 横向偏移（Phigros positionX → 像素）
	position.x = float(info.metadata.get("position_x", 0.0)) * line.pix_per_X

	# 反向（below）音符整体翻转（Phigros 角度取负转弧度）
	if int(info.metadata.get("above", -1)) == 1:
		rotation = deg_to_rad(-180)

	# hold 初始长度：节点已在树中（池复用）时立即设置；
	# 首次从池取出（bind 于入树前调用）时 hold 子节点尚未 _ready，等 _ready() 补设
	if note_type == 3 and is_inside_tree():
		_apply_hold_length()


# hold 初始长度（与原公式一致）：(end−hit)ms → 秒 × speed × px/Y ÷ 缩放
func _apply_hold_length() -> void:
	var hold_len = (info.end_time_ms - info.hit_time_ms) / 1000.0 \
		* float(info.metadata.get("speed", 1.0)) * line.pix_per_Y / 0.12
	hold.set_length(hold_len)


# ============================================================
# reset_for_pool — 释放回池前恢复初始形态（line 在 release 前调用）
# ============================================================
func reset_for_pool() -> void:
	judged = false
	visible = false
	note_id = ""
	info = {}
	line = null
	position = Vector2.ZERO
	rotation = 0.0
	note_type = 1

	# 若此前是 hold 形态：销毁 hold 子节点、恢复 normal_note
	if hold:
		hold.queue_free()
		hold = null
	$normal_note.visible = true
	$normal_note.texture = tap_tex


# ============================================================
# set_type — 设置音符类型
# set_note_type: 1=tap 2=drag 3=hold 4=flick
# mh: 是否多押高亮（Multi-Highlight），true = 使用 _mh 纹理
# ============================================================
func set_type(set_note_type: int, mh: bool) -> void:
	note_type = set_note_type
	match set_note_type:
		1:
			$normal_note.texture = tap_mh_tex if mh else tap_tex
			$normal_note.visible = true
		2:
			$normal_note.texture = drag_mh_tex if mh else drag_tex
			$normal_note.visible = true
		4:
			$normal_note.texture = flick_mh_tex if mh else flick_tex
			$normal_note.visible = true
		3:
			# Hold 特殊处理：隐藏普通方块，换为 hold.tscn 实例
			# （normal_note 保留在场景中以便池复用，仅隐藏）
			$normal_note.visible = false
			if hold == null:
				var h = hold_scene.instantiate()
				h.mh = mh
				add_child(h)
				hold = h


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
	if note_type == 3:
		speed_mult = 1.0
	position.y = float(pos[0]) * above * speed_mult * line.pix_per_Y

	if note_type == 3:
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


# autoplay 判定：计分 + 特效（tap/drag/flick）。
# 不销毁节点，标记 judged + 隐藏，由 line 下一帧释放回池复用。
func _judge() -> void:
	if judged:
		return
	judged = true

	if note_type != 3:
		position.y = 0
		line.world.spawn_hit_effect(global_position)
	line.world.on_note_judged()

	visible = false
