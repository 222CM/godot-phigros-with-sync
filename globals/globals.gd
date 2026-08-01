extends Node
# ============================================================
# globals.gd — 全局自动加载单例
# 存放跨场景共享的状态：运行模式、时间、文件路径、谱面数据
# 项目设置中配置为 autoload，任何脚本都能直接 Globals.xxx 访问
# ============================================================

# --- 运行模式 ---
enum Mode { PLAY, RENDER }     # 播放模式 / 外部驱动时间模式（测试用）
var mode = Mode.PLAY           # 当前模式，默认播放

# --- 游戏时间 ---
# 两种模式下 current_time 的含义一致：从音乐开头算起的逻辑时间（秒）
# PLAY：每帧从 music_player 的播放位置同步
# RENDER：由外部（测试脚本）逐帧直接设置
var current_time = 0.0

# --- 文件路径 ---
var level_path = ""            # 谱面 JSON 文件的磁盘路径
var background_path = ""       # 背景图片路径（暂未使用）
var music_path = ""            # 音乐文件路径（ogg/mp3/wav）

# --- 谱面数据 ---
# SyncDocumentChart（由 PhigrosChart 转换器从谱面 JSON 转换而来）。
# 后端计算（BPM/时间换算、线动画采样、音符位置）全部由 Sync 引擎承担。
var chart
