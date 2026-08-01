extends CanvasLayer
# ============================================================
# import_screen.gd — 主场景 ImportScreen 的脚本
# 这是项目启动后第一个看到的界面，提供：
#   1. 手动选择谱面、背景图、音乐文件
#   2. 一键导入 ZIP 压缩包（自动解压识别文件类型）
#   3. 播放模式启动入口
# 点击播放后隐藏自身，动态创建 World 场景
# ============================================================

# World 场景的预加载引用和实例
var world_scene = preload("res://world.tscn")
var world = null        # 当前活跃的 World 实例，用于播放结束后清理

# Phigros JSON → SyncDocumentChart 转换器（-s 脚本模式不注册全局 class_name，显式 preload）
const PhigrosChart := preload("res://chart/phigros_chart.gd")

func _ready():
	# 按钮的信号连接：
	# 前三个 → 手动选文件；zip → 一键导入；play → 启动
	$level_file.pressed.connect(func(): _pick_file("level"))
	$pict_file.pressed.connect(func(): _pick_file("picture"))
	$music_file.pressed.connect(func(): _pick_file("music"))
	$zip_file.pressed.connect(_pick_zip)
	$play.pressed.connect(_start)


# ============================================================
# 文件选择 — 使用系统原生文件对话框
# DisplayServer.file_dialog_show() 弹出系统对话框，选完后回调指定函数
# ============================================================

# 根据 type 弹出对应类型过滤的对话框
func _pick_file(type: String):
	match type:
		"level":
			DisplayServer.file_dialog_show("选择关卡 JSON", "", "", false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.json"]), _on_level_selected)
		"picture":
			DisplayServer.file_dialog_show("选择背景图", "", "", false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.png,*.jpg,*.svg ; 图片文件"]), _on_picture_selected)
		"music":
			DisplayServer.file_dialog_show("选择音乐", "", "", false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.ogg,*.mp3,*.wav ; 音频文件"]), _on_music_selected)

# 三个文件选择回调：把选中路径写入 Globals，更新按钮文字
func _on_level_selected(status: bool, paths: PackedStringArray, _filter_index: int):
	if status:
		Globals.level_path = paths[0]
		$level_file.text = "关卡：" + paths[0].get_file()
		# 立即解析 JSON → Globals.chart
		_parse_chart(paths[0])

func _on_picture_selected(status: bool, paths: PackedStringArray, _filter_index: int):
	if status:
		Globals.background_path = paths[0]
		$pict_file.text = "图片：" + paths[0].get_file()

func _on_music_selected(status: bool, paths: PackedStringArray, _filter_index: int):
	if status:
		Globals.music_path = paths[0]
		$music_file.text = "音乐：" + paths[0].get_file()


# ============================================================
# ZIP 导入 — 一键解压并自动识别文件
# ============================================================

func _pick_zip():
	DisplayServer.file_dialog_show("选择压缩包", "", "", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		PackedStringArray(["*.zip ; ZIP 压缩包"]),
		_on_zip_selected)

func _on_zip_selected(status: bool, paths: PackedStringArray, _filter_index: int):
	if not status:
		return
	_extract_and_detect(paths[0])

func _extract_and_detect(zip_path: String):
	# 先清空上一轮的所有路径和按钮文字
	Globals.level_path = ""
	Globals.background_path = ""
	Globals.music_path = ""
	$level_file.text = "关卡："
	$pict_file.text = "图片："
	$music_file.text = "音乐："

	# 解压到 user://imported 目录（独立于项目源文件）
	var out_dir = ProjectSettings.globalize_path("user://imported")
	DirAccess.make_dir_recursive_absolute(out_dir)

	# 遍历 ZIP 内所有文件，按扩展名分类
	var zip = ZIPReader.new()
	var err = zip.open(zip_path)
	if err != OK:
		print("无法打开 ZIP 文件")
		return

	var level_found = ""
	var picture_found = ""
	var music_found = ""

	var files = zip.get_files()
	for f in files:
		if f.ends_with("/"):
			continue

		var ext = f.get_extension().to_lower()
		var save_path = out_dir + "/" + f.get_file()

		var data = zip.read_file(f)
		if data == null or data.size() == 0:
			continue
		var out_file = FileAccess.open(save_path, FileAccess.WRITE)
		if out_file:
			out_file.store_buffer(data)
			out_file.close()

		# 每种类型只取第一个匹配文件
		if level_found == "" and ext == "json":
			level_found = save_path
		elif picture_found == "" and ext in ["png", "jpg", "jpeg", "svg"]:
			picture_found = save_path
		elif music_found == "" and ext in ["ogg", "mp3", "wav"]:
			music_found = save_path

	zip.close()

	# 更新按钮文字和 Globals 路径
	if level_found != "":
		Globals.level_path = level_found
		$level_file.text = "关卡：" + level_found.get_file()
	if picture_found != "":
		Globals.background_path = picture_found
		$pict_file.text = "图片：" + picture_found.get_file()
	if music_found != "":
		Globals.music_path = music_found
		$music_file.text = "音乐：" + music_found.get_file()

	# 解压后自动解析谱面 JSON → Globals.chart
	if Globals.level_path != "":
		_parse_chart(Globals.level_path)


# ============================================================
# 启动游戏
# ============================================================

func _start():
	# 必须选关卡和音乐才能启动
	if Globals.level_path == "" or Globals.music_path == "":
		print("请先选择关卡和音乐")
		return

	# 隐藏导入界面，动态创建 World 场景作为同级节点
	hide()
	world = world_scene.instantiate()
	add_sibling(world)      # World 成为 ImportScreen 的兄弟节点

	# 播放模式：World 开始运行，播放音乐
	Globals.mode = Globals.Mode.PLAY
	world.get_node("music_player").stream = _load_audio(Globals.music_path)
	world.get_node("music_player").play()
	world.play_finished.connect(_on_play_finished)


# ============================================================
# _parse_chart — 解析谱面 JSON → SyncDocumentChart（存入 Globals.chart）
# ============================================================
func _parse_chart(path: String):
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("无法读取谱面文件: ", path)
		return
	var text = f.get_as_text()
	f.close()
	var raw = JSON.parse_string(text)
	if raw == null or not raw is Dictionary:
		print("JSON 解析失败: ", path)
		return
	Globals.chart = PhigrosChart.to_document(raw)
	var track_count: int = Globals.chart.root_tracks.size()
	var note_count := 0
	for track in Globals.chart.root_tracks:
		note_count += track.get_note_count()
	print("谱面解析完成: %d 条判定线, %d 个音符" % [track_count, note_count])


# ============================================================
# _load_audio — 加载外部音频文件（.ogg/.mp3/.wav）
# ResourceLoader.load() 不能直接加载外部文件，需要根据扩展名创建对应流
# ============================================================
func _load_audio(path: String) -> AudioStream:
	var ext = path.get_extension().to_lower()
	if ext == "ogg":
		return AudioStreamOggVorbis.load_from_file(path)
	elif ext == "mp3":
		return AudioStreamMP3.load_from_file(path)
	elif ext == "wav":
		return AudioStreamWAV.load_from_file(path)
	return null


# 播放结束回调：重新显示导入界面，清理旧 World
func _on_play_finished():
	show()
	if world:
		world.queue_free()
		world = null
