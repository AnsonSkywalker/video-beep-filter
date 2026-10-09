#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bili_danmaku_to_ass.py —— 把 B站（主站格式）XML 弹幕转换成 ASS 字幕文件。

用途：把 B站直播录播的弹幕硬编码进视频（配合 ffmpeg 的 ass 滤镜）。

字体样式的来源（按需求）：
  1) 用 --style-from 指到一个抖音(DanmakuRender)生成的 .ass 时，直接从中提取：
       - [V4+ Styles] 里「被事件引用最多的那条样式」→ 字体/字号/颜色/描边等
       - 事件里的 \\move 车道 y 值与步长（换算成「相对字号的比例」）、滚动时长
  2) 不指定时使用下面的 BUILTIN_* 常量：这些值就是从本项目抖音 ASS 弹幕
     （DanmakuRender 生成，PlayRes 720x1280）里提取出来的，用来保持两平台统一。

缩放规则（与分辨率、横竖屏都无关）：
  scale = sqrt(目标宽×目标高 / 参考画布宽×参考画布高)，即「按画面面积开方」。
    * 宽高比相同时，它恰好等于「目标高 ÷ 参考高」——所以抖音竖屏 720p → B站竖屏
      1080p 的结果与按高度缩放完全一致。
    * 宽高比不同时（抖音竖屏 → B站横屏，或抖音 1080p → B站 720p），按面积缩放能
      保证弹幕相对画面的大小不变，不会出现横屏字号被高度比压到 20 多像素、
      或反过来被放大到糊脸的情况。
  车道几何不搬绝对值，而是用「车道 y ÷ 字号」的比例乘到目标字号上，换朝向也不会
  跑出画面。车道数固定 10 条（DanmakuRender 每场录制的车道数会变，不是稳定样式），
  可用 --lanes 调整。字号可用 --font-size 直接指定。

弹幕互相压叠：同一条车道要满足「后一条已完全进入画面、且不会被前一条追上」才允许
再放；车道实在不够时按最小重叠「堆叠」放置，**不丢弃任何弹幕**（可用 --lanes 加宽
车道来减少堆叠）。

B站 XML 的 <d p="时间,模式,字号,颜色,时间戳,弹幕池,用户,行号">文本</d>：
  * 支持模式 1(右→左滚动)、6(左→右滚动)、4(底部固定)、5(顶部固定)
  * 模式 7/8/9(高级/代码/BAS 弹幕) 无法用 ASS 简单表达，跳过并计数
"""

from __future__ import annotations

import argparse
import collections
import math
import os
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET

# ─────────────────────────── 内置抖音参考样式 ───────────────────────────
# 从本项目抖音 ASS 弹幕（DanmakuRender 输出，PlayRes 720x1280）中提取，勿随意改动，
# 它们决定了与抖音成品的观感一致性。
BUILTIN_STYLE = {
    "Name": "R2L",
    "Fontname": "Microsoft YaHei",
    "Fontsize": "42",
    "PrimaryColour": "&H33FFFFFF",
    "SecondaryColour": "&H33000000",
    "OutlineColour": "&H33000000",
    "BackColour": "&H4F0000FF",
    "Bold": "-1",
    "Italic": "0",
    "Underline": "0",
    "StrikeOut": "0",
    "ScaleX": "100",
    "ScaleY": "100",
    "Spacing": "0",
    "Angle": "0",
    "BorderStyle": "1",
    "Outline": "1.0",
    "Shadow": "0",
    "Alignment": "1",
    "MarginL": "0",
    "MarginR": "0",
    "MarginV": "0",
    "Encoding": "0",
}
BUILTIN_PLAYRES = (720.0, 1280.0)     # 参考样式的画布尺寸
BUILTIN_LANE_FIRST_Y = 62.0           # 第一条车道 y
BUILTIN_LANE_STEP = 48.0              # 车道间距
BUILTIN_LANES = 10                    # 车道数
BUILTIN_SCROLL_DURATION = 16.0        # 单条滚动弹幕的存活时间（秒）
# 车道几何相对字号的比值（62/42、48/42）。跨分辨率/跨横竖屏时用比值推导，
# 比直接搬绝对值安全：换朝向时不会出现车道跑出画面或挤成一条线。
BUILTIN_LANE_FIRST_RATIO = BUILTIN_LANE_FIRST_Y / float(BUILTIN_STYLE["Fontsize"])
BUILTIN_LANE_STEP_RATIO = BUILTIN_LANE_STEP / float(BUILTIN_STYLE["Fontsize"])

# B站固定弹幕（模式 4/5）在屏时间
FIXED_DURATION = 4.0

STYLE_FORMAT = [
    "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour",
    "OutlineColour", "BackColour", "Bold", "Italic", "Underline", "StrikeOut",
    "ScaleX", "ScaleY", "Spacing", "Angle", "BorderStyle", "Outline", "Shadow",
    "Alignment", "MarginL", "MarginR", "MarginV", "Encoding",
]


# ─────────────────────────── 工具函数 ───────────────────────────
def fmt_time(seconds: float) -> str:
    """ASS 时间戳 H:MM:SS.cc（厘秒）。"""
    if seconds < 0:
        seconds = 0.0
    cs = int(round(seconds * 100))
    h, rem = divmod(cs, 360000)
    m, rem = divmod(rem, 6000)
    s, c = divmod(rem, 100)
    return f"{h}:{m:02d}:{s:02d}.{c:02d}"


def char_units(ch: str) -> int:
    """字符的宽度单位：全角/宽字符 2 个单位，半角 1 个（单位 = 字号/2）。

    与抖音(DanmakuRender)的估算方式一致：终点 x 是 字号/2 的整数倍。
    """
    if ch in "\r\n\t":
        return 1
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text: str, fontsize: float) -> float:
    """估算文本像素宽度 = (字号/2) × 宽度单位数。"""
    return sum(char_units(c) for c in text) * (fontsize / 2.0)


def escape_ass_text(text: str) -> str:
    """处理 ASS 文本里的特殊字符，保证原样显示。"""
    # 换行一律压平为空格：弹幕本身是单行
    text = re.sub(r"[\r\n\t]+", " ", text)
    # 反斜杠与花括号是 ASS 的控制字符，按 libass 约定转义
    text = text.replace("\\", "\\\\")
    text = text.replace("{", "\\{").replace("}", "\\}")
    return text


# ─────────────────────── 从参考 ASS 提取样式/版面 ───────────────────────
def parse_style_line(fmt: list[str], line: str) -> dict:
    """解析一行 Style: 定义（按 Format 字段顺序，末字段可含逗号）。"""
    body = line.split(":", 1)[1].strip()
    parts = body.split(",", len(fmt) - 1)
    return {k: v.strip() for k, v in zip(fmt, parts)}


def load_reference(path: str) -> dict:
    """读取抖音参考 ASS，返回样式 + 版面几何（已按参考画布原始比例）。"""
    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        lines = fh.read().splitlines()

    playres_x, playres_y = BUILTIN_PLAYRES
    style_fmt = None
    styles = {}
    events = []
    in_events = False

    for line in lines:
        s = line.strip()
        if s.startswith("PlayResX"):
            playres_x = float(re.split(r"[:=]", s, 1)[1].strip())
        elif s.startswith("PlayResY"):
            playres_y = float(re.split(r"[:=]", s, 1)[1].strip())
        elif s.startswith("Format:") and not in_events:
            style_fmt = [x.strip() for x in s.split(":", 1)[1].split(",")]
        elif s.startswith("Style:") and style_fmt:
            st = parse_style_line(style_fmt, s)
            styles[st.get("Name", "")] = st
        elif s.startswith("[Events]"):
            in_events = True
        elif s.startswith("Dialogue:") and in_events:
            events.append(s)

    if not styles:
        return {}

    # 取「被事件引用最多」的样式，即为弹幕主样式
    used = collections.Counter()
    for ev in events:
        parts = ev.split(":", 1)[1].split(",", 9)
        if len(parts) > 3:
            used[parts[3].strip()] += 1
    style_name = used.most_common(1)[0][0] if used else next(iter(styles))
    style = dict(styles.get(style_name) or next(iter(styles.values())))

    # 从事件里提取车道几何 / 起点 x / 滚动时长
    ys, start_xs, durations = [], [], []
    for ev in events:
        m = re.search(r"\\move\((-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\)", ev)
        if m:
            start_xs.append(float(m.group(1)))
            ys.append(float(m.group(2)))
        m2 = re.match(r"Dialogue:\s*\d+,(\d+):(\d+):([\d.]+),(\d+):(\d+):([\d.]+),", ev)
        if m2:
            st = int(m2.group(1)) * 3600 + int(m2.group(2)) * 60 + float(m2.group(3))
            en = int(m2.group(4)) * 3600 + int(m2.group(5)) * 60 + float(m2.group(6))
            if en > st:
                durations.append(round(en - st, 2))

    lanes = sorted(set(ys))
    result = {
        "path": path,
        "style": style,
        "playres": (playres_x, playres_y),
        "lanes": len(lanes) if lanes else None,
        "lane_first_y": lanes[0] if lanes else None,
        "lane_step": (lanes[1] - lanes[0]) if len(lanes) > 1 else None,
        "start_x": collections.Counter(start_xs).most_common(1)[0][0] if start_xs else None,
        "duration": collections.Counter(durations).most_common(1)[0][0] if durations else None,
    }
    return result


# ─────────────────────────── 解析 B站 XML ───────────────────────────
def load_xml_danmaku(path: str):
    """返回 [(time, mode, fontsize, color, text), ...]，按时间升序。"""
    with open(path, "rb") as fh:
        data = fh.read()
    root = ET.fromstring(data)
    out = []
    for d in root.iter("d"):
        p = d.get("p") or ""
        fields = p.split(",")
        if len(fields) < 4:
            continue
        try:
            t = float(fields[0])
            mode = int(float(fields[1]))
            fsize = int(float(fields[2]))
            color = int(float(fields[3]))
        except ValueError:
            continue
        text = (d.text or "").strip()
        if not text:
            continue
        out.append((t, mode, fsize, color, text))
    out.sort(key=lambda x: x[0])
    return out


# ─────────────────────────── 车道分配 ───────────────────────────
def assign_lane(lane_state, n_lanes, start, width, screen_w, duration):
    """给一条滚动弹幕挑一条不重叠的车道。

    两条弹幕（宽度 w_p / w_n，同一条车道，同一存活时长 D）不重叠的充要条件
    （屏幕宽 W，后一条比前一条晚 Δt 出发）：
        Δt >= D · max(w_p, w_n) / (W + max(w_p, w_n))
    推导：后一条必须先「完全进入画面」；若它比前一条更宽（更快），还需在
    前一条移出前不被追上。上式同时覆盖这两种情况。

    返回 (车道号, 是否需要强制重叠放置)。找不到空车道时选「最快空出来」的那条。
    """
    best_lane, best_need = None, None
    for i in range(n_lanes):
        prev = lane_state[i]
        if prev is None:
            return i, False
        p_start, p_width = prev
        dt = start - p_start
        need = duration * max(p_width, width) / (screen_w + max(p_width, width))
        if dt >= need:
            return i, False
        slack = need - dt                      # 越小越接近可用
        if best_need is None or slack < best_need:
            best_need, best_lane = slack, i
    return best_lane, True


# ─────────────────────────── 主流程 ───────────────────────────
def build(xml_path, out_path, width, height, ref, offset, lanes_override,
          duration_override, keep_colors, verbose, fontsize_override=None):
    events = load_xml_danmaku(xml_path)
    if not events:
        raise SystemExit(f"XML 中没有解析到任何弹幕: {xml_path}")

    # ---- 样式与几何：按「画面总面积」缩放，与宽高比无关 ----
    # scale = sqrt(目标面积 / 参考画布面积)。
    #   * 宽高比相同时它恰好等于「目标高/参考高」，所以竖屏 720p→1080p 的结果与旧的
    #     按高度缩放完全一致（一个像素都不变）。
    #   * 宽高比不同时（例如抖音竖屏 720x1280 → B站横屏 1280x720，或者反过来
    #     抖音 1080p → B站 720p），按面积缩放能保证弹幕相对画面的大小不变，
    #     不会出现横屏下字号被高度比压成 20 多像素、或者反过来被放大到糊脸。
    style = dict(BUILTIN_STYLE)
    ref_playres_x, ref_playres_y = BUILTIN_PLAYRES
    lane_first_ratio = BUILTIN_LANE_FIRST_RATIO
    lane_step_ratio = BUILTIN_LANE_STEP_RATIO
    n_lanes = BUILTIN_LANES
    ref_lanes = None
    duration = BUILTIN_SCROLL_DURATION
    src = "内置（从抖音 ASS 弹幕提取）"
    has_ref_geom = False

    if ref:
        src = f"参考 ASS: {os.path.basename(ref.get('path') or '')}"
        style = dict(ref.get("style") or BUILTIN_STYLE)
        ref_playres_x, ref_playres_y = ref.get("playres") or BUILTIN_PLAYRES
        # 车道数不继承参考：DanmakuRender 的车道数随每场录制的弹幕密度变化
        # （同一主播的两份成品就分别是 10 条和 9 条），不是稳定的样式属性。
        ref_lanes = ref.get("lanes")
        if ref.get("duration"):
            duration = ref["duration"]
        has_ref_geom = ref.get("lane_first_y") is not None and ref.get("lane_step")

    if not ref_playres_x or ref_playres_x <= 0:
        ref_playres_x = BUILTIN_PLAYRES[0]
    if not ref_playres_y or ref_playres_y <= 0:
        ref_playres_y = BUILTIN_PLAYRES[1]

    ref_fontsize = float(style.get("Fontsize") or BUILTIN_STYLE["Fontsize"])
    scale = math.sqrt((width * height) / (ref_playres_x * ref_playres_y))

    # 车道的「首行位置 / 间距」都相对字号，这样换分辨率、换朝向都能推导出合理版面：
    # 取参考 ASS 里 车道y ÷ 参考字号 的比例，再乘到目标字号上。
    if has_ref_geom and ref_fontsize > 0:
        lane_first_ratio = ref["lane_first_y"] / ref_fontsize
        lane_step_ratio = ref["lane_step"] / ref_fontsize

    if fontsize_override and fontsize_override > 0:
        fontsize = float(fontsize_override)
        scale = fontsize / ref_fontsize if ref_fontsize else 1.0
    else:
        fontsize = ref_fontsize * scale
    style["Fontsize"] = f"{fontsize:.2f}"
    # 描边宽度等也随字号等比缩放，保持视觉比例一致
    for key in ("Outline", "Shadow", "Spacing"):
        try:
            style[key] = f"{float(style.get(key) or 0) * scale:.2f}"
        except ValueError:
            pass

    lane_first_y = fontsize * lane_first_ratio
    lane_step = fontsize * lane_step_ratio
    if lanes_override is not None:
        n_lanes = lanes_override
    if duration_override is not None:
        duration = duration_override
    # 车道不能超出画面（末条车道的文字底边也要留在画面内）
    max_lanes = max(1, int((height - lane_first_y - fontsize) // lane_step) + 1)
    if n_lanes > max_lanes:
        n_lanes = max_lanes

    # ---- 逐条生成事件 ----
    lane_state = [None] * n_lanes
    top_state, bottom_state = [None] * n_lanes, [None] * n_lanes
    lines_out = []
    stats = collections.Counter()
    skipped_modes = collections.Counter()
    non_white = 0

    for raw_t, mode, _fsize, color, text in events:
        t = raw_t + offset
        if mode not in (1, 6, 4, 5):
            skipped_modes[mode] += 1
            continue
        if color != 0xFFFFFF:
            non_white += 1

        body = escape_ass_text(text)
        if keep_colors and color != 0xFFFFFF:
            # B站颜色是十进制 RGB，ASS 是 &HBBGGRR&
            bgr = f"{color & 0xFF:02X}{(color >> 8) & 0xFF:02X}{(color >> 16) & 0xFF:02X}"
            body = "{\\c&H%s&}" % bgr + body

        if mode in (1, 6):
            w = text_width(text, fontsize)
            lane, forced = assign_lane(lane_state, n_lanes, t, w, width, duration)
            lane_state[lane] = (t, w)
            if forced:
                stats["重叠放置"] += 1
            y = lane_first_y + lane * lane_step
            if mode == 1:      # 右 → 左
                move = f"\\move({width:g},{y:g},{-w:g},{y:g})"
            else:              # 左 → 右
                move = f"\\move({-w:g},{y:g},{width:g},{y:g})"
            start, end = t, t + duration
            head = "{" + move + "}"
        else:
            # 固定弹幕：模式 5 顶部、模式 4 底部，中心对齐
            stack = top_state if mode == 5 else bottom_state
            lane, forced = assign_lane(stack, n_lanes, t, 0.0, width, FIXED_DURATION)
            stack[lane] = (t, 0.0)
            if forced:
                stats["重叠放置"] += 1
            an = 8 if mode == 5 else 2
            y = lane_first_y + lane * lane_step if mode == 5 else height - (lane_first_y + lane * lane_step)
            head = "{\\an%d\\pos(%g,%g)}" % (an, width / 2.0, y)
            start, end = t, t + FIXED_DURATION

        if end <= 0:
            stats["超出片头丢弃"] += 1
            continue
        if start < 0:
            start = 0.0

        lines_out.append(
            "Dialogue: 0,%s,%s,%s,,0,0,0,,%s%s"
            % (fmt_time(start), fmt_time(end), style.get("Name", "R2L"), head, body)
        )
        stats["已生成"] += 1

    # ---- 写出 ASS ----
    header = [
        "[Script Info]",
        f"Title: B站直播弹幕（由 {os.path.basename(xml_path)} 转换）",
        "ScriptType: v4.00+",
        "Collisions: Normal",
        f"PlayResX: {int(round(width))}",
        f"PlayResY: {int(round(height))}",
        "Timer: 100.0000",
        "WrapStyle: 2",
        "ScaledBorderAndShadow: yes",
        "",
        "[V4+ Styles]",
        "Format: " + ", ".join(STYLE_FORMAT),
        "Style: " + ",".join(str(style.get(k, "")) for k in STYLE_FORMAT),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(header + lines_out) + "\n")

    if verbose:
        print(f"  样式来源 : {src}")
        if ref:
            print(f"  参考画布 : {int(ref_playres_x)}x{int(ref_playres_y)}"
                  f"  (宽高比 {ref_playres_x / ref_playres_y:.3f})")
        print(f"  目标画布 : {int(width)}x{int(height)}  (宽高比 {width / height:.3f})")
        print(f"  缩放     : {scale:.3f}  (按画面面积开方，与横竖屏无关)")
        if ref and abs((ref_playres_x / ref_playres_y) - (width / height)) > 0.02:
            print(f"  [提示]   参考与目标宽高比不同（例如竖屏参考→横屏视频）："
                  f"字号按面积比缩放，车道按字号比例重新推导，版面不会跑出画面")
        print(f"  字体     : {style.get('Fontname')} {fontsize:.1f}px "
              f"(描边 {style.get('Outline')}, 透明度 {style.get('PrimaryColour')})")
        print(f"  车道     : {n_lanes} 条  y={lane_first_y:.0f} 起 步长 {lane_step:.0f}"
              f"  底边 y={lane_first_y + (n_lanes - 1) * lane_step + fontsize:.0f}")
        print(f"  滚动时长 : {duration:g}s")
        if ref_lanes and ref_lanes != n_lanes:
            print(f"  [说明]   参考 ASS 自身用了 {ref_lanes} 条车道；车道数不随参考变化，"
                  f"本项目固定 {n_lanes} 条（可用 -Lanes 调整）")
        print(f"  弹幕总数 : {len(events)}  已生成 {stats['已生成']}")
        if stats["重叠放置"]:
            print(f"  车道不足、按堆叠(重叠)放置: {stats['重叠放置']} 条（不丢弃任何弹幕）")
        if non_white:
            extra = "（已按弹幕颜色上色）" if keep_colors else "（已统一为参考样式的白色）"
            print(f"  非白色弹幕: {non_white} 条{extra}")
        if skipped_modes:
            detail = ", ".join(f"模式{k}×{v}" for k, v in sorted(skipped_modes.items()))
            print(f"  跳过(高级/代码/BAS弹幕): {sum(skipped_modes.values())} 条 ({detail})")
    return stats["已生成"]


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="把 B站（主站格式）XML 弹幕转换为 ASS 字幕（样式可取自抖音 ASS）",
    )
    ap.add_argument("input", help="B站 XML 弹幕文件")
    ap.add_argument("-o", "--output", help="输出的 .ass 路径（默认与输入同名）")
    ap.add_argument("--width", type=float, help="目标视频宽度（PlayResX）")
    ap.add_argument("--height", type=float, help="目标视频高度（PlayResY）")
    ap.add_argument("--style-from", help="抖音(DanmakuRender) ASS，用它提取字体样式与版面")
    ap.add_argument("--offset", type=float, default=0.0,
                    help="给所有弹幕时间叠加的秒数（例如从第 300s 剪出的片段用 -300）")
    ap.add_argument("--lanes", type=int, help="覆盖车道数")
    ap.add_argument("--duration", type=float, help="覆盖滚动弹幕存活时长（秒）")
    ap.add_argument("--font-size", type=float,
                    help="直接指定字号（像素，相对目标画布）。给了就完全按它来，"
                         "不再由参考样式推算；描边等仍按该字号与参考字号的比例缩放")
    ap.add_argument("--keep-colors", action="store_true",
                    help="保留 XML 中的弹幕颜色（默认统一用参考样式的颜色）")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit(f"找不到 XML 文件: {args.input}")
    out = args.output or os.path.splitext(args.input)[0] + "_bili.ass"

    ref = None
    if args.style_from:
        if not os.path.isfile(args.style_from):
            raise SystemExit(f"找不到参考 ASS: {args.style_from}")
        ref = load_reference(args.style_from)
        if not ref:
            print(f"  [警告] 参考 ASS 里没解析到样式，改用内置抖音样式: {args.style_from}",
                  file=sys.stderr)

    width = args.width or BUILTIN_PLAYRES[0]
    height = args.height or BUILTIN_PLAYRES[1]

    n = build(args.input, out, width, height, ref, args.offset,
              args.lanes, args.duration, args.keep_colors, not args.quiet,
              args.font_size)
    if not args.quiet:
        print(f"  已写出   : {out}")
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
