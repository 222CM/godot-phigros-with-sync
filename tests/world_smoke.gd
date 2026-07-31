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

	# 逐帧推进（等价 RenderManager 循环）
	for i in frames:
		Globals.current_time = i / FPS
		world.update_simulation()
		for l in world.lines:
			if not l.position.is_finite() or not is_finite(l.rotation):
				_fail("line %s 在 t=%.2f 出现非有限值: pos=%s rot=%s" % [l.track_id, Globals.current_time, l.position, l.rotation])
				break
		if world.combo >= total_notes:
			break   # 全部判定后可提前结束

	var remaining := 0
	for l in world.lines:
		remaining += l.notes.size()
	print("帧后: combo=%d/%d, 剩余未判定音符节点=%d" % [world.combo, total_notes, remaining])

	# 短谱（mini 夹具应在帧窗口内全部判定）；任意谱至少推进了判定
	if total_notes <= 20:
		_expect(world.combo == total_notes and remaining == 0,
			"全部音符已判定并回收（combo=%d/%d, remaining=%d）" % [world.combo, total_notes, remaining])
	else:
		_expect(world.combo > 0, "已发生判定（combo=%d）" % world.combo)

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
