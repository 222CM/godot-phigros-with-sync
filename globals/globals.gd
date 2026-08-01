extends Node
# ============================================================
# globals.gd — 全局自动加载单例
# 存放跨场景共享的状态：运行模式、时间、文件路径、谱面数据
# 项目设置中配置为 autoload，任何脚本都能直接 Globals.xxx 访问
# ============================================================

# --- 运行模式 ---
enum Mode { PLAY, RENDER }     # 播放模式 / 渲染模式
var mode = Mode.PLAY           # 当前模式，默认播放

# --- 窗口大小 ---

# --- 游戏时间 ---
# 两种模式下 current_time 的含义一致：从音乐开头算起的逻辑时间（秒）
# PLAY：每帧从 music_player 的播放位置同步
# RENDER：由 RenderManager 逐帧直接设置
var current_time = 0.0

# --- 游戏状态 ---
# game_started = true 后 World 的 update_simulation 才会执行
# 在 import_screen 点击播放/渲染时设为 true
var game_started = false

# --- 文件路径 ---
var level_path = ""            # 谱面 JSON 文件的磁盘路径
var background_path = ""       # 背景图片路径（暂未使用）
var music_path = ""            # 音乐文件路径（ogg/mp3/wav）

# --- 谱面数据 ---
# SyncDocumentChart（由 PhigrosChart 转换器从谱面 JSON 转换而来）。
# 后端计算（BPM/时间换算、线动画采样、音符位置）全部由 Sync 引擎承担。
var chart

# ============================================================
# 打击音效录制（仅 RENDER 模式使用）
# 渲染时将音效触发时间记录到列表，合成视频时混入音轨
# ============================================================
var hit_sounds = []


# 记录一次音效触发：在 time 秒时播放 sound_path
func add_hit_sound(time: float, sound_path: String):
	hit_sounds.append({"time": time, "file": sound_path})

# 每次渲染开始前清空音效列表
func clear_hit_sounds():
	hit_sounds.clear()
