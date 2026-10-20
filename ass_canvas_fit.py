#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ass_canvas_fit.py —— 烧录前把 ASS 的画布（PlayRes）适配到视频画布。

为什么需要这一步
----------------
DanmakuRender 生成的抖音 ASS 有时候不是按录播视频的分辨率写的：例如本项目里
`21点51分` 那一场的 ASS 是 PlayRes 1920x1080（横屏），视频却是 720x1280（竖屏）。

libass 在 PlayRes 与视频画布比例不一致时，x 坐标和字号不是同一个缩放比例：
  * x 坐标      ≈ 视频宽 / PlayResX
  * 字号 / 字宽 ≈ 视频高 / PlayResY
滚动弹幕的 `\\move(x1,y1,x2,y2)` 里，x2 通常写的是「负的文字宽度」；它按 x 比例
缩小、文字本身却按字号比例放大，于是事件结束时文字还有一大半留在画面里，看起来
就是「弹幕滑到一半突然整条消失」。

适配规则
--------
把 PlayRes 改成目标画布 W×H，并做以下变换：
  * 样式：Fontsize / Outline / Shadow / Spacing / MarginV × sy，
          MarginL / MarginR × sx
  * 普通坐标：x × sx，y × sy
  * 水平滚动 `\\move`：进场侧 x 乘 sx，出场侧 x 乘 sy
      - 右→左：起点（右侧）乘 sx，终点（负宽度）乘 sy
      - 左→右：起点（负宽度）乘 sy，终点（右侧）乘 sx
    因为终点编码的是「文字宽度」，必须跟着字号走，不能跟着画布宽度走。
  * `\\pos` / `\\org` / `\\clip` / `\\iclip`：x × sx，y × sy
  * `\\fs` / `\\bord` / `\\shad` / `\\xshad` / `\\yshad` / `\\blur` / `\\be` / `\\fsp`：× sy
  * 文字内容、事件时间、行顺序、[Fonts]/[Graphics] 均原样保留

比例一致时（默认容差 1%）不做任何改动；需要强制重排时加 `--force`。
默认原地改写（临时文件 + os.replace），也可以 `-o` 另存。

用法：
    python ass_canvas_fit.py danmaku.ass --width 720 --height 1280
    python ass_canvas_fit.py in.ass -o out.ass --width 1080 --height 1920 -q
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys

# ASS/SSA 未声明 PlayRes 时 libass 的默认值
DEFAULT_PLAYRES = (384.0, 288.0)
# 宽高比差异在这个比例以内视为「同一画布比例」，不做重排
ASPECT_TOLERANCE = 0.01

# 与 danmaku_censor.py 保持一致：`\{` 是正文里的转义花括号，不是特效指令
OVERRIDE_RE = re.compile(r"(?<!\\)\{([^}]*)\}")
MOVE_RE = re.compile(r"\\move\(([^)]*)\)")
POS_RE = re.compile(r"\\pos\(([^)]*)\)")
ORG_RE = re.compile(r"\\org\(([^)]*)\)")
ICLIP_RE = re.compile(r"\\iclip\(([^)]*)\)")
CLIP_RE = re.compile(r"\\clip\(([^)]*)\)")
# \fs 后面不能跟 cx/cy（\fscx / \fscy 是百分比，不缩放）；\fsp 要先于 \fs 匹配
SCALAR_TAG_RE = re.compile(
    r"\\(fsp|fs(?!c[xy])|bord|xshad|yshad|shad|blur|be)(-?\d+(?:\.\d+)?)"
)


def fmt_num(value: float) -> str:
    """把缩放后的数值写成 ASS 里好看的形式（去掉无意义的 .0 / 末尾 0）。"""
    if abs(value) < 1e-9:
        return "0"
    if abs(value - round(value)) < 1e-6:
        return str(int(round(value)))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def to_float(text: str):
    """解析一个数值参数；不是数字时返回 None。"""
    try:
        return float(text.strip())
    except (TypeError, ValueError):
        return None


def scale_plain_xy(args: str, sx: float, sy: float, count: int = 2):
    """缩放 `\pos` / `\org` 的 (x,y[, ...])。"""
    parts = [p.strip() for p in args.split(",")]
    if len(parts) < count:
        return None
    values = [to_float(p) for p in parts[:count]]
    if any(v is None for v in values):
        return None
    scaled = [values[0] * sx, values[1] * sy]
    rest = parts[count:]
    return ",".join([fmt_num(v) for v in scaled] + rest)


def scale_move(args: str, sx: float, sy: float):
    """缩放 `\move(x1,y1,x2,y2[,t1,t2])`。

    水平滚动时，出场侧 x 表示文字宽度，必须乘字号比例 sy；进场侧 x 是画布坐标，乘 sx。
    不能一律乘 sx，否则 PlayRes 比例不一致时文字还没滑完事件就结束了。
    """
    parts = [p.strip() for p in args.split(",")]
    if len(parts) < 4:
        return None
    vals = [to_float(p) for p in parts[:4]]
    if any(v is None for v in vals):
        return None
    x1, y1, x2, y2 = vals
    if abs(y1 - y2) < 1e-6 and x1 >= 0 > x2:
        # 右 → 左：x1 是右侧进场点，x2 是左侧的 -文字宽度
        nx1, nx2 = x1 * sx, x2 * sy
    elif abs(y1 - y2) < 1e-6 and x1 < 0 <= x2:
        # 左 → 右：x1 是左侧的 -文字宽度，x2 是右侧进场点
        nx1, nx2 = x1 * sy, x2 * sx
    else:
        # 非水平滚动（或起止点都在同一侧）：按普通坐标处理
        nx1, nx2 = x1 * sx, x2 * sx
    return ",".join(
        [fmt_num(nx1), fmt_num(y1 * sy), fmt_num(nx2), fmt_num(y2 * sy)] + parts[4:]
    )


def scale_clip(args: str, sx: float, sy: float):
    """缩放 `\clip` / `\iclip` 的矩形坐标。

    支持两种写法：
      \\clip(x1,y1,x2,y2)
      \\clip(mode,x1,y1,x2,y2)
    矢量写法（\\clip(m 0 0 l ...)）原样保留。
    """
    parts = [p.strip() for p in args.split(",")]
    if len(parts) == 4:
        vals = [to_float(p) for p in parts]
        if any(v is None for v in vals):
            return None
        return ",".join(
            [fmt_num(vals[0] * sx), fmt_num(vals[1] * sy),
             fmt_num(vals[2] * sx), fmt_num(vals[3] * sy)]
        )
    if len(parts) == 5:
        mode = to_float(parts[0])
        vals = [to_float(p) for p in parts[1:]]
        if mode is None or int(mode) != mode or not 0 <= mode <= 3:
            return None
        if any(v is None for v in vals):
            return None
        return ",".join(
            [fmt_num(mode), fmt_num(vals[0] * sx), fmt_num(vals[1] * sy),
             fmt_num(vals[2] * sx), fmt_num(vals[3] * sy)]
        )
    return None


def scale_block(inner: str, sx: float, sy: float, counters: dict) -> str:
    """处理一个 {...} 里的全部特效指令。"""
    def sub_move(m):
        out = scale_move(m.group(1), sx, sy)
        if out is None:
            return m.group(0)
        counters["move"] += 1
        return r"\move(" + out + ")"

    def sub_pos(m):
        out = scale_plain_xy(m.group(1), sx, sy)
        if out is None:
            return m.group(0)
        counters["pos"] += 1
        return r"\pos(" + out + ")"

    def sub_org(m):
        out = scale_plain_xy(m.group(1), sx, sy)
        if out is None:
            return m.group(0)
        counters["org"] += 1
        return r"\org(" + out + ")"

    def sub_iclip(m):
        out = scale_clip(m.group(1), sx, sy)
        if out is None:
            return m.group(0)
        counters["clip"] += 1
        return r"\iclip(" + out + ")"

    def sub_clip(m):
        out = scale_clip(m.group(1), sx, sy)
        if out is None:
            return m.group(0)
        counters["clip"] += 1
        return r"\clip(" + out + ")"

    def sub_scalar(m):
        value = to_float(m.group(2))
        if value is None:
            return m.group(0)
        counters["scalar"] += 1
        return "\\" + m.group(1) + fmt_num(value * sy)

    inner = MOVE_RE.sub(sub_move, inner)
    inner = POS_RE.sub(sub_pos, inner)
    inner = ORG_RE.sub(sub_org, inner)
    inner = ICLIP_RE.sub(sub_iclip, inner)
    inner = CLIP_RE.sub(sub_clip, inner)
    inner = SCALAR_TAG_RE.sub(sub_scalar, inner)
    return inner


def rewrite_overrides(text: str, sx: float, sy: float, counters: dict) -> str:
    """只改写 {...} 里的指令，正文（含 \\{ 转义）保持原样。"""
    return OVERRIDE_RE.sub(
        lambda m: "{" + scale_block(m.group(1), sx, sy, counters) + "}", text
    )


def parse_style_line(line: str, fmt: list[str]):
    """把 `Style: ...` 拆成 (前导空白, 字段值列表)；字段数不够时返回 None。"""
    m = re.match(r"^(\s*)Style\s*:\s*(.*)$", line, re.IGNORECASE)
    if not m:
        return None
    indent, body = m.group(1), m.group(2)
    parts = body.split(",", len(fmt) - 1)
    if len(parts) < len(fmt):
        return None
    return indent, [p.strip() for p in parts]


def scale_style_line(line: str, fmt: list[str], sx: float, sy: float,
                     counters: dict):
    parsed = parse_style_line(line, fmt)
    if parsed is None:
        return line
    indent, values = parsed
    index = {name.strip().lower(): i for i, name in enumerate(fmt)}

    def scale_field(name: str, factor: float):
        i = index.get(name)
        if i is None or i >= len(values):
            return
        v = to_float(values[i])
        if v is not None:
            values[i] = fmt_num(v * factor)

    scale_field("fontsize", sy)
    scale_field("outline", sy)
    scale_field("shadow", sy)
    scale_field("spacing", sy)
    scale_field("marginl", sx)
    scale_field("marginr", sx)
    scale_field("marginv", sy)
    counters["style"] += 1
    return indent + "Style: " + ",".join(values)


def split_event(line: str, text_index: int):
    """把一行 events 拆成 (前缀, 正文字段)。text_index 默认 9（标准格式）。"""
    head, sep, body = line.partition(":")
    if sep != ":" or head.strip().lower() != "dialogue":
        return None, None
    parts = body.split(",", text_index)
    if len(parts) <= text_index:
        return None, None
    prefix = head + ":" + ",".join(parts[:text_index]) + ","
    return prefix, parts[text_index]


def scale_event_margins(parts: list[str], sx: float, sy: float):
    """标准 9 字段格式里，事件级 MarginL/R/V 也按画布缩放。"""
    if len(parts) < 9:
        return
    for i, factor in ((5, sx), (6, sx), (7, sy)):
        v = to_float(parts[i])
        if v is not None:
            parts[i] = fmt_num(v * factor)


def fit_lines(lines: list[str], width: float, height: float, force: bool,
              quiet: bool):
    """返回 (新行列表, 是否做了改写, 源宽, 源高)。"""
    src_x = src_y = None
    for line in lines:
        s = line.strip()
        if s.lower().startswith("playresx"):
            m = re.match(r"^\s*PlayResX\s*:\s*(\d+(?:\.\d+)?)", line, re.IGNORECASE)
            if m:
                src_x = float(m.group(1))
        elif s.lower().startswith("playresy"):
            m = re.match(r"^\s*PlayResY\s*:\s*(\d+(?:\.\d+)?)", line, re.IGNORECASE)
            if m:
                src_y = float(m.group(1))

    # 缺失的那一维按 libass 的规则从另一维 + 视频比例推算（bilibili 转换器也这么理解）
    if src_x is None and src_y is None:
        src_x, src_y = DEFAULT_PLAYRES
    elif src_x is None:
        src_x = src_y * (width / height)
    elif src_y is None:
        src_y = src_x / (width / height)

    if src_x <= 0 or src_y <= 0:
        raise ValueError(f"ASS 的 PlayRes 无效: {src_x}x{src_y}")

    ratio_src = src_x / src_y
    ratio_dst = width / height
    if not force and abs(ratio_src - ratio_dst) / ratio_dst <= ASPECT_TOLERANCE:
        if not quiet:
            print(f"  画布适配: ASS {fmt_num(src_x)}x{fmt_num(src_y)} 与视频 "
                  f"{fmt_num(width)}x{fmt_num(height)} 比例一致，未改动")
        return lines, False, src_x, src_y

    sx = width / src_x
    sy = height / src_y
    counters = {"style": 0, "move": 0, "pos": 0, "org": 0, "clip": 0, "scalar": 0}
    out = []
    section = ""
    style_fmt = None
    event_text_index = 9
    saw_x = saw_y = False

    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s.lower()
            out.append(line)
            continue

        low = s.lower()
        if section in ("[v4+ styles]", "[v4 styles]") and low.startswith("format:"):
            style_fmt = [x.strip() for x in s.split(":", 1)[1].split(",")]
            out.append(line)
            continue
        if section in ("[v4+ styles]", "[v4 styles]") and low.startswith("style:") and style_fmt:
            out.append(scale_style_line(line, style_fmt, sx, sy, counters))
            continue
        if section == "[events]" and low.startswith("format:"):
            names = [x.strip().lower() for x in s.split(":", 1)[1].split(",")]
            if "text" in names:
                event_text_index = names.index("text")
            out.append(line)
            continue
        if section == "[events]" and low.startswith("dialogue:"):
            prefix, text = split_event(line, event_text_index)
            if prefix is None:
                out.append(line)
                continue
            # 标准格式下顺手缩放事件级 margin；非标准格式不动。
            # 注意只能去掉 prefix 末尾的“一个”分隔逗号：空 Effect 字段本身也占一个逗号，
            # 用 rstrip(",") 会把两个逗号一起吃掉，正文就会被挤进 Effect 字段。
            if event_text_index == 9 and prefix.endswith(","):
                fields = prefix[:-1].split(",", 8)
                if len(fields) == 9:
                    scale_event_margins(fields, sx, sy)
                    prefix = ",".join(fields) + ","
            out.append(prefix + rewrite_overrides(text, sx, sy, counters))
            continue

        # Script Info 的 PlayRes / LayoutRes
        m = re.match(r"^(\s*PlayResX\s*:\s*).*$", line, re.IGNORECASE)
        if m:
            out.append(m.group(1) + fmt_num(width))
            saw_x = True
            continue
        m = re.match(r"^(\s*PlayResY\s*:\s*).*$", line, re.IGNORECASE)
        if m:
            out.append(m.group(1) + fmt_num(height))
            saw_y = True
            continue
        m = re.match(r"^(\s*LayoutResX\s*:\s*).*$", line, re.IGNORECASE)
        if m:
            out.append(m.group(1) + fmt_num(width))
            continue
        m = re.match(r"^(\s*LayoutResY\s*:\s*).*$", line, re.IGNORECASE)
        if m:
            out.append(m.group(1) + fmt_num(height))
            continue

        out.append(line)

    # 原文件没写 PlayRes：补上，让 libass 不再自行推算
    if not saw_x or not saw_y:
        insert_at = 0
        for i, line in enumerate(out):
            if line.strip().lower() == "[script info]":
                insert_at = i + 1
                break
        missing = []
        if not saw_x:
            missing.append(f"PlayResX: {fmt_num(width)}")
        if not saw_y:
            missing.append(f"PlayResY: {fmt_num(height)}")
        if insert_at == 0:
            out[0:0] = ["[Script Info]"] + missing
        else:
            out[insert_at:insert_at] = missing

    if not quiet:
        print(f"  画布适配: ASS {fmt_num(src_x)}x{fmt_num(src_y)} → 视频 "
              f"{fmt_num(width)}x{fmt_num(height)}"
              f"（x×{sx:.4g}, 字号/y×{sy:.4g}；样式 {counters['style']} 条，"
              f"\\move {counters['move']} 条，\\pos/\\org {counters['pos'] + counters['org']} 条，"
              f"\\clip {counters['clip']} 条，字号/描边等 {counters['scalar']} 处）")
    return out, True, src_x, src_y


def write_lines(path: str, lines: list[str]):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="把 ASS 的 PlayRes/坐标/字号适配到目标视频画布，修复滚动弹幕提前消失",
    )
    ap.add_argument("input", help="输入 .ass")
    ap.add_argument("-o", "--output", help="输出路径；默认原地改写输入文件")
    ap.add_argument("--width", type=float, required=True, help="目标视频宽度（PlayResX）")
    ap.add_argument("--height", type=float, required=True, help="目标视频高度（PlayResY）")
    ap.add_argument("--force", action="store_true",
                    help="即使宽高比一致也强制重排（用于测试）")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        raise SystemExit(f"找不到 ASS 文件: {args.input}")
    if args.width <= 0 or args.height <= 0:
        raise SystemExit("--width / --height 必须是正数")

    with open(args.input, "r", encoding="utf-8-sig", errors="replace") as fh:
        lines = fh.read().splitlines()

    try:
        new_lines, changed, src_x, src_y = fit_lines(
            lines, args.width, args.height, args.force, args.quiet
        )
    except ValueError as exc:
        raise SystemExit(str(exc))

    out = args.output or args.input
    same = os.path.normcase(os.path.abspath(out)) == os.path.normcase(os.path.abspath(args.input))
    if changed:
        write_lines(out, new_lines)
    elif not same:
        shutil.copyfile(args.input, out)

    if not args.quiet and (changed or not same):
        print(f"  已写出   : {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
