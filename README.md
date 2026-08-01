# godot-phigros-with-sync

Phigros 官谱自动播放 + 视频渲染器，基于 Godot 4.6.3 开发。只支持官谱。

后端计算（BPM/时间换算、判定线动画采样、音符位置计算）由
**[Sync](https://github.com/222CM/Sync) 节奏游戏引擎**（`addons/sync` 单一 GDExtension，0.6.0+）承担，
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
SyncDocumentChart（Sync 文档谱面）
   │  SyncChartPlayer.set_document_chart()（编译）
   ▼
SyncChart（只读编译谱面）
   │  每帧以 chart_ms 显式采样
   ▼
判定线 position/rotation/alpha 轴、音符归一化位置、note info
   │  游戏侧渲染层（line.gd 时间窗口驱动 + SyncNodePool / notes.gd）
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
- **音符节点池化（渲染层）**：不再一次性实例化整条线的全部音符。Phigros 官谱存在
  `speed=9999` 的瞬移/传送段，音符位置会一帧内跳变穿越可视窗口，Sync 的可见性增量
  cursor 会漏检这类音符，因此本层采用**时间窗口驱动**：每帧二分查找
  hit_time 落在 `(chart_ms, chart_ms + LEAD_MS]` 内的音符（默认提前 1.5s 实例化，
  保证完整呈现飞行过程），通过 diff 驱动 **SyncNodePool** 的 acquire/release——
  判定完成的音符恢复初始形态后还池复用。屏幕外音符不实例化、不参与每帧计算，
  节点数 ≈ 时间窗口内音符数（实测 996 音符谱峰值活跃仅 34），而非谱面总量。
- **时间轴**：音乐播放位置 + 音频缓冲延迟补偿（PLAY 模式）/ 渲染帧时间（RENDER 模式），
  每帧 `chart_ms = current_time × 1000 + offset`（Sync 约定 chart = audio + offset）。
- **判定**：Sync 引擎不内置判定，autoplay 判定在游戏侧按 `hit_time_ms` / `end_time_ms` 触发。

### Sync 依赖

| 组件 | 仓库 | 说明 |
|---|---|---|
| sync（单扩展） | https://github.com/222CM/Sync | 0.6.0 起提供 get_note_ids_in_time_window（按 hit 时间二分，免疫 speed 瞬移）、SyncDocumentChart.compile() 独立编译入口、step_ms/set_chart_time_ms 外部时间注入 |

本项目 `addons/` 下已附带官方 0.6.0 构建（Windows x86_64 debug + release，godot-cpp 4.3，4.6.3/4.7 兼容）。
重新构建见仓库 README（`scons -f SConstruct.extension target=… platform=…`）。

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
├── world.gd            # 游戏核心：编译 SyncChart、可见集分发、判定线实例化、分数
├── lines/              # 判定线渲染层（采样 Sync 轴 + 可见性驱动 + SyncNodePool）
├── notes/              # 音符节点（tap / hold / drag / flick，池化复用）
├── hit_effect/         # 打击特效
├── globals/            # 全局自动加载单例
├── render_manager/     # 渲染管理器（废弃中）
├── note_resource/      # 音符纹理、音效
├── addons/sync/        # Sync 0.6.0 单扩展（GDExtension，含 debug + release 构建）
└── tests/              # 后端参照对照测试 + 全流程冒烟测试（含池化断言）
```

## 测试

```bash
# 后端等价性测试（转换器 + Sync 采样 vs 重构前算法，Python 独立参照）
python tests/reference/reference_phigros.py tests/fixtures/mini_chart.json tests/fixtures/mini_expected.json
godot --headless --path . -s res://tests/backend_smoke.gd

# world 全流程冒烟（自动判定全部音符 + 节点池化断言）
godot --headless --path . tests/world_smoke.tscn
# 用任意官谱跑（示例：996 李化禹 IN）
godot --headless --path . tests/world_smoke.tscn -- --chart=<谱面.json> --frames=8800
```

## 已知问题与限制

- 每线 BPM 不同时按线缩放拍值近似（官谱通常全线同 BPM，样例 996 全谱 140）
- `offset` 方向按 Sync 约定（chart = audio + offset）；样例 offset=0，未在含偏移官谱上实测
- 低帧率下 note 移动有细微抖动（帧时序偏差，历史遗留）
- 渲染模式暂时不可用（音效过多导致 ffmpeg 命令行溢出）
