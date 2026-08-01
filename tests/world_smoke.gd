extends Node
# ============================================================
# world_smoke.gd — world 场景全流程冒烟测试（以 tests/world_smoke.tscn 运行）
#
# 模拟 import_screen 启动后的运行：转换谱面 → 实例化 world.tscn →
# 以 RENDER 模式逐帧设置 current_time 并调用 update_simulation()。
# 验证：
#   - 场景树无脚本错误、所有线/音符节点正常生成
#   - 逐帧位置有限（无 NaN/Inf）
#   - 音符全部被 autoplay 判定并回收（短谱断言 combo 达标）
#   - 节点池化生效：池峰值规模 < 总音符数（未一次性实例化全部节点）
#
# 用法：
#   godot --headless --path . tests/world_smoke.tscn
#   godot --headless --path . tests/world_smoke.tscn -- --chart=<谱面.json> --frames=900
# ============================================================

const PhigrosChart := preload("res://chart/phigros_chart.gd")
const WORLD_SCENE := preload("res://world.tscn")
const FPS := 60.0

var failures := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var chart_path := "res://tests/fixtures/mini_chart.json"
	var frames := 900
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--chart="):
			chart_path = arg.trim_prefix("--chart=")
		elif arg.begins_with("--frames="):
			frames = int(arg.trim_prefix("--frames="))

	print("=== world_smoke: %s (%d 帧) ===" % [chart_path, frames])

	var raw = JSON.parse_string(FileAccess.get_file_as_string(chart_path))
	if raw == null or not raw is Dictionary:
		_fail("无法解析谱面 %s" % chart_path)
		get_tree().quit(1)
		return

	# 模拟 import_screen._parse_chart 之后的状态
	Globals.chart = PhigrosChart.to_document(raw)
	Globals.mode = Globals.Mode.RENDER
	Globals.background_path = ""

	var world = WORLD_SCENE.instantiate()
	add_child(world)
	await get_tree().process_frame

	var play_chart: SyncChart = world.play_chart
	var total_notes := play_chart.get_total_note_count()
	print("谱面: %d 条线, %d 个音符" % [play_chart.get_track_count(), total_notes])
	_expect(world.lines.size() == play_chart.get_track_count(),
		"world 生成 %d 条判定线（期望 %d）" % [world.lines.size(), play_chart.get_track_count()])

	# 逐帧推进（等价播放模式每帧驱动）
	var max_active := 0        # 任意帧的峰值活跃节点数（位置窗口内）
	var peak_pool_size := 0    # 池实例化峰值 = 各线 (active + free) 之和
	var t_start := Time.get_ticks_usec()
	var frames_run := 0
	for i in frames:
		frames_run += 1
		Globals.current_time = i / FPS
		world.update_simulation()
		var act := 0
		var pool_size := 0
		for l in world.lines:
			if not l.position.is_finite() or not is_finite(l.rotation):
				_fail("line %s 在 t=%.2f 出现非有限值: pos=%s rot=%s" % [l.track_id, Globals.current_time, l.position, l.rotation])
				break
			act += l.active_notes.size()
			if l.pool != null:
				pool_size += l.pool.get_active_count() + l.pool.get_free_count()
			# hold 从池取出后必须立即具备正确长度（不在判定后才补齐）
			for nid in l.active_notes:
				var n = l.active_notes[nid]
				if n.note_type == 3 and (n.hold == null or n.hold.length <= 0.0):
					_fail("hold %s 在 acquire 后未设置长度（%s）" % [nid, l.track_id])
		max_active = max(max_active, act)
		peak_pool_size = max(peak_pool_size, pool_size)
		if world.combo >= total_notes:
			# 判定发生在 update_simulation 末尾，补跑一帧让已判定音符完成释放回池
			Globals.current_time = (i + 1) / FPS
			world.update_simulation()
			break

	var remaining := 0
	for l in world.lines:
		remaining += l.active_notes.size()
	var t_end := Time.get_ticks_usec()
	print("帧后: combo=%d/%d, 峰值活跃节点=%d, 池峰值规模=%d, 剩余未判定节点=%d"
		% [world.combo, total_notes, max_active, peak_pool_size, remaining])
	print("帧耗时: %.2f ms/帧（%d 帧，纯逻辑不含渲染）" % [(t_end - t_start) / 1000.0 / frames_run, frames_run])

	# 短谱（mini 夹具应在帧窗口内全部判定）；任意谱至少推进了判定
	if total_notes <= 20:
		_expect(world.combo == total_notes and remaining == 0,
			"全部音符已判定并回收（combo=%d/%d, remaining=%d）" % [world.combo, total_notes, remaining])
	else:
		_expect(world.combo > 0, "已发生判定（combo=%d）" % world.combo)

	# 池化生效：池实例化峰值必须小于总音符数（否则等于一次性加载全部节点）。
	# 仅对足够大的谱面断言——极小谱（如 mini 10 音符）池化无收益，跳过强断言。
	# （临时禁池对比期间 pool==null，断言自动跳过；恢复池化后自动生效）
	if total_notes >= 30 and world.lines.size() > 0 and world.lines[0].pool != null:
		_expect(peak_pool_size < total_notes,
			"节点池复用生效：池峰值规模 %d < 总音符 %d" % [peak_pool_size, total_notes])

	if total_notes <= 20:
		_expect(world.score > 0 and world.score <= 1000000, "分数在 (0, 1000000]（%d）" % world.score)

	world.queue_free()
	print("=== 失败: %d ===" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _expect(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
		print("FAIL  %s" % label)


func _fail(label: String) -> void:
	failures += 1
	print("FAIL  %s" % label)
