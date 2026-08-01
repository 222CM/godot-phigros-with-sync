# godot-phigros-with-sync

Phigros 官谱自动播放器，基于 Godot 开发。只支持官谱。

后端计算（BPM/时间换算、判定线动画采样、音符位置计算）由
**[Sync](https://github.com/222CM/Sync) 节奏游戏引擎**（`addons/sync` 单一 GDExtension，0.6.4+）承担，
游戏侧只保留渲染、判定与计分。

## 项目由来

本项目由原项目 **[godot-phigros](https://github.com/CMYC4237/godot-phigros)** 改造而来。
原项目为 Phigros 官谱自动播放器，同样基于 Godot 开发，其后端计算框架——包括
BPM/时间换算（`sec_per_Tick = 1.875 / bpm`）、speed 事件位移积分（手写梯形面积
累计 floorPosition）、判定线动画事件插值与音符位置计算——全部以 GDScript 实现。

本次改造的核心工作是**将上述后端计算框架整体替换为 Sync 引擎**
（C++ GDExtension，`BpmEventList` / `SpeedEventList` / 轴采样等），
游戏侧保留原项目的渲染、判定与计分逻辑；随后在渲染层进一步引入
`SyncNodePool` 节点池化与位置窗口可见性驱动等特性。原项目与本文档
当前描述的后端结构（见「架构」）已不存在一一对应关系。

## 性能

以下为同设备、同一谱面（DESTRUCTION321 AT，2330 音符 / 24 条判定线）、
debug 构建下的实测帧率（含渲染）：

| 阶段 | 改造核心前（原项目，纯 GDScript） | 改造核心后（Sync 引擎 + 节点池） |
|---|---|---|
| 开局 | 约 316 fps，随音符判定销毁逐步上升 | 稳定约 1400 fps，low 帧不低于 1200 fps |

改造前的帧率随音符存量递减（每帧全量更新所有未判定音符，工作量随时间
衰减）；改造后帧率基本恒定——节点池 + 位置窗口使每帧计算量仅与屏幕内
音符数相关，与谱面总音符量解耦。

headless 纯逻辑（不含渲染）的逐音符成本对照，同一谱面（Godot，
RENDER 模式逐帧驱动，`ms/帧`）：

| 场景 | 原项目 | 改造后 | 差异 |
|---|---|---|---|
| 最坏（开局，2330 音符全量更新） | 1.94 ms/帧 | 0.29 ms/帧 | 约 6.7× 提升 |
| 平均（全程 9462 帧） | 1.19 ms/帧 | 0.29 ms/帧 | 约 4.1× 提升 |
| 最优（收尾，音符已几乎清空） | 0.13 ms/帧 | 0.29 ms/帧 | 原项目反超（改造后有固定每帧开销） |

说明：改造后的固定开销来自每帧的批量可见查询与线动画轴采样，与音符
存量无关；原项目在音符清空后退化为纯线动画插值，成本极低。因此两版本
的差距随音符存量减少而收敛，性能优势主要体现在开局与密集段。

## 功能

- 支持 ZIP 导入或手动选择谱面、曲绘、音乐
- 自动判定全部 note（autoplay），显示分数、Combo、进度条
- Dual Kawase Blur 曲绘模糊背景
- 打击特效（逐帧动画 + easeOutQuart 粒子）
- 多押高亮、Hold 缩短等视觉细节

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
- **音符节点池化（渲染层）**：不再一次性实例化整条线的全部音符。Phigros 官谱音符
  没有"永久渲染"标签，表演谱存在 `speed=9999` 瞬移/传送段——音符可能**提前数秒到
  百余秒出现在屏幕上等待**（996 谱实测 73/996 音符在 hit 前 >5s 已进入屏幕范围），
  基于 hit 时间的时间窗口必然钳制它们。因此本层采用**批量可见查询驱动**：
  每帧一次 `get_visible_note_ids(chart_ms, 0.0, 4.0)`（Sync 0.6.1 位置窗口参数化，
  C++ 内循环，GDScript 侧无逐音符调用边界，实测 2330 音符批量 0.005ms）——
  **渲染区间 [0, 4]**：判定线后方（已越过）不显示（Phigros 语义），前方 4 屏
  开始渲染（表演谱音符可从远处高速飞入）；另以 hit 前 20ms 时间窗口兜底
  （`get_note_ids_in_time_window`，防 speed=9999 一帧穿越、批量查询 cursor 漏检）。
  判定先行、释放后置（避免 hit/end 帧被释放逻辑抢先回收而漏判），判定完成或
  离开窗口后 reset/release 回池复用。屏幕外音符不实例化、不参与每帧计算：
  节点数 ≈ 位置窗口内音符数（996 谱峰值 55、2330 压力谱峰值 138），纯逻辑帧耗时
  996 谱 0.29ms / 2330 压力谱 0.42ms。
- **时间轴**：音乐播放位置 + 音频缓冲延迟补偿（PLAY 模式）/ 外部逐帧设置（RENDER 模式，测试用），
  每帧 `chart_ms = current_time × 1000 + offset`（Sync 约定 chart = audio + offset）。
- **判定**：Sync 引擎不内置判定，autoplay 判定在游戏侧按 `hit_time_ms` / `end_time_ms` 触发。

### Sync 依赖

| 组件 | 仓库 | 说明 |
|---|---|---|
| sync（单扩展） | https://github.com/222CM/Sync | 0.6.4：get_visible_note_ids 位置窗口参数化（window_lo/hi）、get_note_ids_in_time_window（按 hit 时间二分）、SyncDocumentChart.compile() 独立编译入口；0.6.4 修复负速段批量可见查询二分游标漏检 |

本项目 `addons/` 下已附带官方 0.6.4 构建（Windows x86_64 debug + release，godot-cpp 4.3，兼容 Godot 4.3+）。
重新构建见仓库 README（`scons -f SConstruct.extension target=… platform=…`）。

## 运行

1. 用 Godot 打开项目（首次需生成 `.godot/extension_list.cfg`，编辑器会自动完成）
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
├── note_resource/      # 音符纹理、音效
├── addons/sync/        # Sync 0.6.4 单扩展（GDExtension，含 debug + release 构建）
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
