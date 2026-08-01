extends Node2D
# ============================================================
# world.gd — 游戏世界主逻辑
# World 场景是动态创建的（由 ImportScreen 在点击播放/渲染时实例化）
#
# 后端计算由 Sync 引擎（addons/sync 单扩展，0.6.0+）承担：
#   1. PhigrosChart 转换器把谱面 JSON 转成 SyncDocumentChart（Globals.chart）
#   2. 本场景用 SyncDocumentChart.compile() 编译成只读 SyncChart
#   3. 每帧以 chart_ms 驱动各判定线；音符渲染由判定线的
#      「时间窗口驱动 + SyncNodePool」管理（见 lines/line.gd）
# 本场景保留：判定线实例化、计分/combo、HUD、特效入口。
# ============================================================

signal play_finished

# 预加载
var hit_effect_scene = preload("res://hit_effect/hit_effect.tscn")
var line_scene = preload("res://lines/line.tscn")

# 线列表
var lines = []

# Sync 编译后的只读谱面（后端数据源，由 line/note 采样）
var play_chart: SyncChart
var chart_offset_ms := 0.0

# 音符渲染位置窗口（归一化位置：0=判定线，正=判定线前，负=已越过）
# 判定线后方（已越过）不显示（Phigros 语义，判定后音符即消失），
# 前方 4 屏开始渲染（表演谱音符可从 4+ 屏外高速飞入，保证完整呈现飞行过程）
const VIS_WINDOW_LO := 0.0
const VIS_WINDOW_HI := 4.0

# 分数 & combo
var score = 0
var combo = 0
var score_per_note = 0.0
var total_duration = 0.0


func _ready():
	play_chart = _compile_chart()
	_spawn_lines(_build_multihit_map())
	_setup_background()
	_setup_audio()
	_calc_score_per_note()
	_create_hud()


# ============================================================
# 初始化
# ============================================================

# 编译 SyncDocumentChart → SyncChart（0.6.0 起提供独立编译入口，无需挂节点）
func _compile_chart() -> SyncChart:
	var pc: SyncChart = Globals.chart.compile()
	chart_offset_ms = pc.get_offset_ms()
	return pc


# 多押标记：hit_time_ms 相同的相邻音符成对标记（与原实现按 time 相等语义一致）
func _build_multihit_map() -> Dictionary:
	var pairs: Array = []
	for tid in play_chart.get_track_ids():
		for nid in play_chart.get_note_ids_for_track(tid):
			var hit_ms := float(play_chart.get_note_info(nid).hit_time_ms)
			pairs.append({"note_id": nid, "hit_time_ms": hit_ms})
	pairs.sort_custom(func(a, b): return a.hit_time_ms < b.hit_time_ms)

	var multihit := {}
	if pairs.size() >= 2:
		for i in range(pairs.size() - 1):
			if is_equal_approx(pairs[i].hit_time_ms, pairs[i + 1].hit_time_ms):
				multihit[pairs[i].note_id] = true
				multihit[pairs[i + 1].note_id] = true
	return multihit


# 生成所有判定线（一条线 = 一个 Sync 轨道）
func _spawn_lines(multihit: Dictionary) -> void:
	for tid in play_chart.get_track_ids():
		var l = line_scene.instantiate()
		l.setup(self, tid, play_chart, multihit)
		$lines_container.add_child(l)
		lines.append(l)


# 加载曲绘作为模糊变暗背景（Dual Kawase Blur 插件 → 实时模糊）
func _setup_background() -> void:
	if Globals.background_path == "":
		return
	var img = Image.load_from_file(Globals.background_path)
	if not img:
		return
	var bg = $bg_layer/BlurY/SubViewport/BlurX/SubViewport/background
	bg.texture = ImageTexture.create_from_image(img)
	var a = 0.5
	bg.self_modulate = Color(a, a, a, 1.0)  # 变暗 70%
	var s = max(960.0 / img.get_width(), 540.0 / img.get_height())
	bg.scale = Vector2(s, s)
	# 调模糊强度（默认 8.0，越大越糊）
	$bg_layer/BlurY.material.set_shader_parameter("radius", 100.0)
	$bg_layer/BlurY/SubViewport/BlurX.material.set_shader_parameter("radius", 100.0)


# 连接结束播放信号 + 获取音乐总时长（用于进度条）
func _setup_audio() -> void:
	$music_player.finished.connect(func(): play_finished.emit())
	if Globals.music_path != "" and Globals.music_path.get_extension().to_lower() == "ogg":
		total_duration = AudioStreamOggVorbis.load_from_file(Globals.music_path).get_length()


# 计算每个 note 的分数（满分 1000000）
func _calc_score_per_note() -> void:
	score_per_note = 1000000.0 / max(1, play_chart.get_total_note_count())


# ============================================================
# 每帧更新
# ============================================================

func _process(delta):
	if Globals.mode == Globals.Mode.PLAY:
		# 从音乐播放器实时同步逻辑时间
		# get_playback_position() 获取当前播放位置（秒）
		# get_time_since_last_mix() 补偿音频缓冲区延迟，提高同步精度
		# RENDER 模式（测试用）：外部逐帧直接设 Globals.current_time
		Globals.current_time = $music_player.get_playback_position() + AudioServer.get_time_since_last_mix()
		update_simulation()


# 每帧调用核心更新函数
func update_simulation():
	# chart 时间 = 音乐时间 + 谱面 offset（Sync 约定：chart = audio + offset）
	var chart_ms: float = Globals.current_time * 1000.0 + chart_offset_ms
	# Sync C++ 批量可见查询（每帧一次，内部循环无 GDScript 逐音符边界开销），
	# 位置窗口 [VIS_WINDOW_LO, VIS_WINDOW_HI]（0~4 屏：判定线后方不显示）
	var visible := play_chart.get_visible_note_ids(chart_ms, VIS_WINDOW_LO, VIS_WINDOW_HI)
	for l in lines:
		l.update_simulation(chart_ms, visible)
	_update_progress()


func _update_progress() -> void:
	if total_duration <= 0:
		return
	var p = Globals.current_time / total_duration
	$hud/progress_fill.anchor_right = p
	$hud/progress_tip.anchor_left = p
	$hud/progress_tip.anchor_right = p


# ============================================================
# 打击特效
# ============================================================

# 在指定的世界坐标生成一个打击特效（hit_effect 实例）
# 特效节点挂在 effects_container 下，独立于音符/判定线
# 特效自身 0.5 秒后自动 queue_free()，调用方不用管清理
func spawn_hit_effect(global_pos: Vector2):
	var fx = hit_effect_scene.instantiate()
	fx.global_position = global_pos
	$effects_container.add_child(fx)


# ============================================================
# 分数 & Combo
# ============================================================

# 由 notes.gd 在 note 被判定时调用
func on_note_judged():
	combo += 1
	score = int(min(score + score_per_note, 1000000))
	_update_hud()

func _update_hud():
	# combo >= 3 才显示
	var show_combo = combo >= 3
	$hud/combo_label.visible = show_combo
	$hud/combo_sub.visible = show_combo
	if show_combo:
		$hud/combo_label.text = str(combo)
	# 分数始终显示，7 位零填充
	$hud/score_label.text = "%07d" % score


# ============================================================
# _create_hud — 创建分数/Combo 的 UI 层
# ============================================================
func _create_hud():
	var hud = CanvasLayer.new()
	hud.name = "hud"
	add_child(hud)

	var font = load("res://cmdysj.ttf")

	# Combo label — 正上方居中
	var combo_label = Label.new()
	combo_label.name = "combo_label"
	combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	combo_label.anchors_preset = Control.PRESET_CENTER_TOP
	combo_label.anchor_left = 0.5
	combo_label.anchor_right = 0.5
	combo_label.anchor_top = 0.0
	combo_label.offset_left = -200
	combo_label.offset_right = 200
	combo_label.offset_top = 7
	combo_label.offset_bottom = 70
	combo_label.visible = false
	combo_label.add_theme_font_override("font", font)
	combo_label.add_theme_font_size_override("font_size", 40)
	hud.add_child(combo_label)

	# AUTOPLAY — combo 下方小字
	var combo_sub = Label.new()
	combo_sub.name = "combo_sub"
	combo_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo_sub.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	combo_sub.anchors_preset = Control.PRESET_CENTER_TOP
	combo_sub.anchor_left = 0.5
	combo_sub.anchor_right = 0.5
	combo_sub.anchor_top = 0.0
	combo_sub.offset_left = -200
	combo_sub.offset_right = 200
	combo_sub.offset_top = 60
	combo_sub.offset_bottom = 90
	combo_sub.text = "AUTOPLAY"
	combo_sub.visible = false
	combo_sub.add_theme_font_override("font", font)
	combo_sub.add_theme_font_size_override("font_size", 17)
	hud.add_child(combo_sub)

	# Score label — 右上方
	var score_label = Label.new()
	score_label.name = "score_label"
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.anchors_preset = Control.PRESET_RIGHT_WIDE
	score_label.anchor_right = 1.0
	score_label.offset_right = -15
	score_label.offset_left = -390
	score_label.offset_top = 10
	score_label.offset_bottom = 45
	score_label.text = "0000000"
	score_label.add_theme_font_override("font", font)
	score_label.add_theme_font_size_override("font_size", 28)
	hud.add_child(score_label)

	# 进度条 — 半透明白色填充，从最左跑到最右
	var progress_fill = ColorRect.new()
	progress_fill.name = "progress_fill"
	progress_fill.anchor_left = 0.0
	progress_fill.anchor_top = 0.0
	progress_fill.anchor_right = 0.0
	progress_fill.offset_top = 0
	progress_fill.offset_bottom = 8
	progress_fill.offset_right = 0
	progress_fill.color = Color(1, 1, 1, 0.5)
	hud.add_child(progress_fill)

	# 进度条端点 — 稍亮的小矩形，紧贴填充末端
	var progress_tip = ColorRect.new()
	progress_tip.name = "progress_tip"
	progress_tip.anchor_left = 0.0
	progress_tip.anchor_top = 0.0
	progress_tip.anchor_right = 0.0
	progress_tip.offset_top = 0
	progress_tip.offset_bottom = 8
	progress_tip.offset_right = 2
	progress_tip.color = Color(1, 1, 1, 1)
	hud.add_child(progress_tip)

	# 暂停键 — 左上角，仅作装饰
	var pause_label = Label.new()
	pause_label.name = "pause_label"
	pause_label.text = "❚❚"
	pause_label.anchor_left = 0.0
	pause_label.anchor_top = 0.0
	pause_label.offset_left = 15
	pause_label.offset_top = 12
	pause_label.add_theme_font_override("font", font)
	pause_label.add_theme_font_size_override("font_size", 32)
	hud.add_child(pause_label)
