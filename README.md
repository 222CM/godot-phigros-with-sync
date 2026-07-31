# godot-phigros-with-sync

Phigros 官谱自动播放 + 视频渲染器，基于 Godot 4.6.3 开发。只支持官谱。

后端计算（BPM/时间换算、判定线动画采样、音符位置计算）由
**[Sync](https://github.com/222CM) 节奏游戏引擎**（`sync_core` + `sync_play_kit` GDExtension）承担，
游戏侧只保留渲染、判定与计分。

## 功能

- 支持 ZIP 导入或手动选择谱面、曲绘、音乐
- 自动判定全部 note（autoplay），显示分数、Combo、进度条
- Dual Kawase Blur 曲绘模糊背景
- 打击特效（逐帧动画 + easeOutQuart 粒子）
- 多押高亮、Hold 缩短等视觉细节

## 渲染模式（⚠️ 暂不可用）

由于 ffmpeg 命令行长度限制，打击音效合成在大量 note 时会溢出。渲染功能已暂时废弃，待未来用预混合音轨方案修复。播放模式完全正常可用。

## 架构

```
Phigros chart JSON
   │  chart/phigros_chart.gd（转换器）
   ▼
SyncDocumentChart（sync_core 共享数据类）
   │  SyncChartPlayer.set_document_chart()（编译）
   ▼
SyncChart（只读编译谱面）
   │  每帧以 chart_ms 显式采样
   ▼
判定线 position/rotation/alpha 轴、音符归一化位置、note info
   │  游戏侧渲染层（line.gd / notes.gd）
   ▼
屏幕
```

- **一条判定线 = 一个 SyncTrack**：
  `judgeLineMoveEvents` → Vector2 轴 `position`（像素坐标，按 formatVersion 换算）、
  `judgeLineRotateEvents` → float 轴 `rotation`、`judgeLineDisappearEvents` → float 轴 `alpha`、
  `speedEvents` → `SyncSpeedAxis "speed"`（音符归一化位置的速度积分源）。
- **音符位置**：`SyncChart.get_note_normalized_position()` 返回速度轴积分距离
  （等价于原实现 `note.floorPosition − 线累计 floor_position`），游戏侧乘以
  `above × speed_mult × 324px` 换算屏幕 y。
- **时间轴**：音乐播放位置 + 音频缓冲延迟补偿（PLAY 模式）/ 渲染帧时间（RENDER 模式），
  每帧 `chart_ms = current_time × 1000 + offset`（Sync 约定 chart = audio + offset）。
- **判定**：Sync 引擎不内置判定，autoplay 判定在游戏侧按 `hit_time_ms` / `end_time_ms` 触发。

### Sync 依赖

| 组件 | 仓库 | 说明 |
|---|---|---|
| sync_core | https://github.com/222CM/SyncCore | 必装基础插件，注册 13 个共享数据类 |
| sync_play_kit | https://github.com/222CM/SyncPlayKit | 运行时类 SyncChart / SyncChartPlayer |

本项目 `addons/` 下已附带 Windows x86_64 构建产物（debug，godot-cpp 4.3，4.6.3 兼容）。
重新构建见各仓库 README（`scons -f SConstruct.extension` + `scons`）。

## 运行

1. 用 Godot 4.6.3 打开项目（首次需生成 `.godot/extension_list.cfg`，编辑器会自动完成）
2. `F5` 运行
3. 导入谱面 ZIP 或手动选 JSON / 曲绘 / 音乐
4. 点击「播放」开始

支持格式：Phigros chart JSON（formatVersion 1 / 3 / 其他）。

## 文件结构

```
├── chart/              # PhigrosChart 转换器（谱面 JSON → SyncDocumentChart）
├── import_screen/      # 主界面，选择谱面/曲绘/音乐
├── world.gd            # 游戏核心：编译 SyncChart、判定线/音符实例化、分数
├── lines/              # 判定线渲染层（采样 Sync 轴）
├── notes/              # 音符节点（tap / hold / drag / flick）
├── hit_effect/         # 打击特效
├── globals/            # 全局自动加载单例
├── render_manager/     # 渲染管理器（废弃中）
├── note_resource/      # 音符纹理、音效
├── addons/sync_core/   # Sync 基础插件（GDExtension）
├── addons/sync_play_kit/  # Sync 播放插件（GDExtension）
└── tests/              # 后端参照对照测试 + 全流程冒烟测试
```

## 测试

```bash
# 后端等价性测试（转换器 + Sync 采样 vs 重构前算法，Python 独立参照）
python tests/reference/reference_phigros.py tests/fixtures/mini_chart.json tests/fixtures/mini_expected.json
godot --headless --path . -s res://tests/backend_smoke.gd

# world 全流程冒烟（自动判定全部音符）
godot --headless --path . tests/world_smoke.tscn
```

## 已知问题与限制

- 每线 BPM 不同时按线缩放拍值近似（官谱通常全线同 BPM，样例 996 全谱 140）
- `offset` 方向按 Sync 约定（chart = audio + offset）；样例 offset=0，未在含偏移官谱上实测
- 低帧率下 note 移动有细微抖动（帧时序偏差，历史遗留）
- 渲染模式暂时不可用（音效过多导致 ffmpeg 命令行溢出）
