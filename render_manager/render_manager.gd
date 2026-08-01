extends Node
# ============================================================
# render_manager.gd — 渲染管理器（自动加载单例）
# 负责将游戏画面导出为视频文件：
#   1. 全速逐帧模拟游戏逻辑（通过设置 Globals.current_time 推进）
#   2. 每帧截图保存为 PNG
#   3. 用 ffmpeg 将帧序列 + 背景音乐 + 打击音效合成为 MP4
#   4. 合成完成后清除中间帧文件，发信号通知 import_screen 恢复界面
# ============================================================

signal render_finished     # 渲染完成信号，import_screen 收到后重新显示

# 渲染参数（由 start_render 的参数设置）
var output_dir             # 输出目录的绝对路径（视频存在这里）
var frames_dir             # 帧序列子文件夹（output_dir/frames）
var fps                    # 渲染帧率（通常 60）
var frame_interval         # fps 对应的单帧间隔（1/fps 秒）
var render_resolution      # 输出视频分辨率 Vector2i


# ============================================================
# start_render — 渲染主入口
# duration:    音乐总时长（秒）
# music_path:  背景音乐文件路径（可选，为空则视频无 BGM）
# set_fps:     输出帧率，默认 60fps
# set_res:     输出分辨率，默认 1920x1080
# set_output_dir: 帧序列和最终视频的输出目录（绝对路径）
# ============================================================
func start_render(duration: float, music_path: String = "", set_fps: int = 60, set_res: Vector2i = Vector2i(1920, 1080), set_output_dir: String = "C:/Users/Huang/Desktop/godot/render_output"):
	fps = set_fps
	frame_interval = 1.0 / fps
	render_resolution = set_res
	output_dir = set_output_dir
	frames_dir = output_dir + "/frames"

	Globals.mode = Globals.Mode.RENDER
	Globals.current_time = 0.0
	Globals.clear_hit_sounds()   # 清空上一轮的打击音效记录

	#清空上一轮的帧序列文件夹（删除后重建）
	var frames_path = ProjectSettings.globalize_path(frames_dir)
	if DirAccess.dir_exists_absolute(frames_path):
		_delete_dir_recursive(frames_path)
	DirAccess.make_dir_recursive_absolute(frames_path)

	var total_frames = int(duration * fps)
	var frame_pattern = frames_dir + "/frame_%06d.png"  # frame_000000.png ~ frame_008399.png

	# --- 关闭垂直同步 + 解除帧率上限：让渲染循环以最快速度跑 ---
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	# --- 切换窗口尺寸到目标分辨率（截图分辨率由此决定）---
	var original_size = DisplayServer.window_get_size()
	DisplayServer.window_set_size(render_resolution)

	# --- 逐帧渲染循环 ---
	for i in range(total_frames):
		# 设定当前帧的逻辑时间（所有物体的位置由此计算）
		Globals.current_time = i * frame_interval
		print(Globals.current_time)
		# 驱动主场景的模拟（音符移动、判定等）
		# 世界场景是 import_screen 动态创建的同级节点（路径固定为 ../world）
		$"../world".update_simulation()

		# 等待 GPU 完成当前帧的绘制后截图
		await RenderingServer.frame_post_draw
		var img = get_viewport().get_texture().get_image()
		img.save_png(frame_pattern % i)

	# --- 恢复正常模式 ---
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	Engine.max_fps = 60
	DisplayServer.window_set_size(original_size)

	# --- ffmpeg 合成视频 ---
	_compose_video(total_frames, music_path)

	# --- 重置状态，通知 import_screen ---
	Globals.game_started = false
	Globals.mode = Globals.Mode.PLAY
	emit_signal("render_finished")


# ============================================================
# _compose_video — 用 ffmpeg 合成最终 MP4
# 将帧序列 PNG + 背景音乐（可选）+ 打击音效（可选）混入一条视频
# 需要系统已安装 ffmpeg 并在 PATH 中
# ============================================================
func _compose_video(total_frames: int, music_path: String):
	var dir = ProjectSettings.globalize_path(output_dir)
	var frame_dir_global = ProjectSettings.globalize_path(frames_dir)
	var frame_pattern = frame_dir_global + "/frame_%06d.png"
	var output_video = dir + "/output.mp4"

	# ffmpeg 命令行参数逐步构建
	# 视频输入源：帧序列 PNG
	var args = ["-r", str(fps), "-i", frame_pattern]

	var has_audio = false
	# 音频输入源：背景音乐（如果提供了且文件存在）
	if music_path != "" and FileAccess.file_exists(music_path):
		args.append("-i")
		args.append(ProjectSettings.globalize_path(music_path))
		has_audio = true

	# --- 打击音效混入 ---
	# 每个音效延迟后混入：adelay=延迟毫秒数:all=1
	# 输入流编号：0=视频、1=背景音乐、2+ = 音效
	var filter_parts = []
	var input_count = 1 + (1 if has_audio else 0)   # 视频流 + 背景音乐流
	var hit_sounds = Globals.hit_sounds.duplicate()
	hit_sounds.sort_custom(func(a, b): return a.time < b.time)

	for hs in hit_sounds:
		args.append("-i")
		args.append(ProjectSettings.globalize_path(hs.file))
		var delay_ms = int(hs.time * 1000)
		filter_parts.append("[%d]adelay=%d:all=1[hs%d]" % [input_count, delay_ms, input_count])
		input_count += 1

	# --- 混音滤镜 ---
	# amix 将背景音乐 + 所有音效合并为一条音轨
	var amix_inputs = ""
	if has_audio:
		amix_inputs += "[1]"
	var hs_count = hit_sounds.size()
	for i in range(2, input_count):
		amix_inputs += "[hs%d]" % i

	if has_audio or hs_count > 0:
		var amix_filter = "%s amix=inputs=%d:duration=first:dropout_transition=0" % [amix_inputs, 1 + hs_count]
		filter_parts.append(amix_filter)

	if filter_parts.size() > 0:
		args.append("-filter_complex")
		args.append(";".join(filter_parts))

	# --- 编码参数 ---
	# 视频：H.264, yuv420p 兼容性最好, crf 18 高质量
	# 音频：AAC 192kbps（仅在有音轨时）
	args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"]
	if has_audio or hs_count > 0:
		args += ["-c:a", "aac", "-b:a", "192k"]
	args.append("-shortest")   # 以最短流为准结束（避免无限长）
	args.append(output_video)

	# 执行 ffmpeg（同步等待完成）
	var output = []
	var exit_code = OS.execute("ffmpeg", args, output, true)
	print("ffmpeg 退出码：", exit_code)
	for line in output: print(line)
	if exit_code == 0:
		print("视频已生成：", output_video)

	# --- 清除帧序列文件夹（只保留最终 MP4）---
	if DirAccess.dir_exists_absolute(frame_dir_global):
		_delete_dir_recursive(frame_dir_global)


# ============================================================
# _delete_dir_recursive — 递归删除文件夹及其所有内容
# ============================================================
func _delete_dir_recursive(path: String):
	var d = DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_delete_dir_recursive(path + "/" + sub)
	d = null  # 释放句柄，否则无法删除自身
	DirAccess.remove_absolute(path)
