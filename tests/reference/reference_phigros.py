#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
reference_phigros.py — Phigros 谱面回放的参照实现（独立于 Sync 引擎）

复刻 godot-phigros 重构前的 line.gd 算法（每帧事件插值 + 梯形速度积分 + 音符 y 公式），
用于生成 tests/backend_smoke.gd 的期望值：
  - 判定线 position（v3 像素坐标）/ rotation（角度原值）/ alpha
  - 线累计 floor_position（速度事件梯形积分）
  - 每个音符的 y（像素）：(floorPosition - line_fp) * above * speed_mult * 324

用法：
  python tests/reference/reference_phigros.py <chart.json> <out.json> [--times 0,100,500,...]
"""

import json
import sys

WINDOW = (960.0, 540.0)
PIX_PER_Y = WINDOW[1] * 0.6          # 324
# 采样时间故意避开精确 tick 边界（旧算法用严格的 `t > endTime` 推进事件索引，
# Sync 引擎在边界即时跳变——这是重构引入的规范差异，测试不覆盖边界点）
DEFAULT_TIMES_MS = [0, 47, 99, 253, 507, 803, 1207, 1513, 2009, 3011,
                    4013, 5009, 6013, 8017, 10009, 12011]


def sec_per_tick(bpm: float) -> float:
    return 1.875 / bpm


def move_value_to_px(a: float, b: float, fmt_ver: int):
    """与原 line.gd 的 formatVersion 分支一致。"""
    if fmt_ver == 1:
        return (int(a) / 1000.0 / 880.0 * WINDOW[0], WINDOW[1] - (int(a) % 1000) / 520.0 * WINDOW[1])
    if fmt_ver == 3:
        return (a * WINDOW[0], (1.0 - b) * WINDOW[1])
    unit = WINDOW[1] * 0.1
    return (WINDOW[0] / 2.0 + a * unit, WINDOW[1] / 2.0 - b * unit)


def sample_events(events, t_sec, spf):
    """复刻 line.gd 的事件索引推进 + 未钳制 t 的 lerp。
    返回 (value_start, value_end, t)"""
    idx = 0
    while idx < len(events) - 1 and t_sec > events[idx]["endTime"] * spf:
        idx += 1
    ev = events[idx]
    s = ev["startTime"] * spf
    e = ev["endTime"] * spf
    t = 1.0 if e == s else (t_sec - s) / (e - s)
    return ev, t


def line_floor_position_events(speed_events, bpm):
    """与原 line.gd 相同：为每个 speed 事件预计算累计 floorPosition。"""
    out = []
    fp = 0.0
    spf = sec_per_tick(bpm)
    for ev in speed_events:
        out.append({"ev": ev, "fp": fp})
        fp += ev["value"] * (ev["endTime"] - ev["startTime"]) * spf
    return out


def floor_position_at(speed_events_with_fp, t_sec, spf):
    ev, t = sample_events([e["ev"] for e in speed_events_with_fp], t_sec, spf)
    ev_fp = next(e["fp"] for e in speed_events_with_fp if e["ev"] is ev)
    start = ev["value"]
    return (start + start + (start - start) * t) * (t_sec - ev["startTime"] * spf) / 2 + ev_fp


def reference_line(line_raw, fmt_ver, times_ms):
    bpm = line_raw["bpm"]
    spf = sec_per_tick(bpm)
    speed_fp = line_floor_position_events(line_raw["speedEvents"], bpm)

    notes = []
    for n in line_raw.get("notesAbove", []):
        notes.append((n, -1))
    for n in line_raw.get("notesBelow", []):
        notes.append((n, 1))

    per_time = []
    for t_ms in times_ms:
        t = t_ms / 1000.0
        # move
        ev, t_move = sample_events(line_raw["judgeLineMoveEvents"], t, spf)
        s = move_value_to_px(ev["start"], ev["start2"], fmt_ver)
        e = move_value_to_px(ev["end"], ev["end2"], fmt_ver)
        mx = s[0] + (e[0] - s[0]) * t_move
        my = s[1] + (e[1] - s[1]) * t_move
        # rotate
        ev, t_rot = sample_events(line_raw["judgeLineRotateEvents"], t, spf)
        rot = ev["start"] + (ev["end"] - ev["start"]) * t_rot
        # alpha
        ev, t_alpha = sample_events(line_raw["judgeLineDisappearEvents"], t, spf)
        alpha = ev["start"] + (ev["end"] - ev["start"]) * t_alpha
        # floor position
        fp = floor_position_at(speed_fp, t, spf)
        # note y（与旧公式 y=(floorPosition−line_fp)×above×speed_mult×324 等价；
        # floorPosition 用速度事件的积分重算，而非 JSON 里 3 位小数的原始值——
        # 原始值的量化误差会产生亚像素级差异，参照用精确积分才能验证引擎等价）
        note_y = []
        for note, above in notes:
            speed_mult = note["speed"] if note["type"] != 3 else 1.0
            fp_note = floor_position_at(speed_fp, note["time"] * spf, spf)
            y = (fp_note - fp) * above * speed_mult * PIX_PER_Y
            note_y.append(y)
        per_time.append({
            "t_ms": t_ms, "mx": mx, "my": my, "rot": rot, "alpha": alpha,
            "fp": fp, "note_y": note_y,
        })

    note_info = []
    for i, (note, above) in enumerate(notes):
        note_info.append({
            "src_index": i, "type": note["type"], "above": above,
            "speed": note["speed"], "floor_position": note["floorPosition"],
            "hit_time_ms": note["time"] * spf * 1000.0,
        })
    return {"bpm": bpm, "per_time": per_time, "notes": note_info}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    chart_path, out_path = sys.argv[1], sys.argv[2]
    times_ms = DEFAULT_TIMES_MS
    for arg in sys.argv[3:]:
        if arg.startswith("--times="):
            times_ms = [int(x) for x in arg.split("=", 1)[1].split(",")]

    with open(chart_path, encoding="utf-8") as f:
        chart = json.load(f)

    fmt_ver = int(chart.get("formatVersion", 3))
    lines = [reference_line(line, fmt_ver, times_ms) for line in chart["judgeLineList"]]

    out = {"times_ms": times_ms, "format_version": fmt_ver, "lines": lines}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("wrote %s (%d lines x %d times)" % (out_path, len(lines), len(times_ms)))


if __name__ == "__main__":
    main()
