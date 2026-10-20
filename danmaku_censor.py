#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
danmaku_censor.py —— 审查弹幕正文：命中敏感数字的整行弹幕直接抹除。

关键词分两层：

  1) 音频侧同源的基础 14 种：直接 `from beep_filter import TARGET_KEYWORDS` 只读复用，
     音频屏蔽那边的识别逻辑一个字都不动，也不会出现两边列表漂移。

  2) 画面/文本侧的扩展：音频只要"听起来像"就够，画面上却是要被机器审核**看到**的，
     所以要把各种视觉写法都覆盖进来（0.64、6.4、６４、陆肆、捌拾玖 …）。

归一化（normalize）之后再比对，比逐个枚举写法稳得多：
  * NFKC：全角转半角（６４ → 64），顺带吃掉 ⑥④、𝟞𝟜 这类兼容字符
  * 去掉所有空白（"6 4" → "64"）
  * 去掉可能夹在数字之间的分隔符（"6.4" / "6,4" / "6·4" / "6/4" / "6-4" → "64"）
  * 汉字的各种写法（六/陆/陸、四/肆、八/捌、九/玖，以及中间的 十/拾）用字符集合
    交叉组合生成关键词，所以 "陆肆"、"六4"、"6拾肆"、"捌拾玖" 之类都在覆盖范围内

于是裸的 "64" / "89" 就能兜住 0.64、6.4、6,4、６．４ 这类所有"数字形态"，
汉字形态则由交叉组合的关键词兜住。

实现要点：
  * 只处理 [Events] 里的 Dialogue 行（真正会被渲染的），Comment 行不动
  * 匹配前先剥掉 {...} 里的 ASS 特效指令 —— 否则 \\move(64,...) 这种坐标会造成误杀
  * 默认原地改写；先写临时文件再替换，避免写坏
  * 想看最终生效的关键词清单：`--list-keywords`
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import sys
import unicodedata

# 关键词表的唯一来源：beep_filter.py（只读复用，不改动音频侧逻辑）
try:
    from beep_filter import TARGET_KEYWORDS as AUDIO_KEYWORDS
except ImportError as exc:  # pragma: no cover
    # 宁可大声失败，也不要在「审查」这一步静默放过
    raise SystemExit(
        f"无法从 beep_filter.py 读取 TARGET_KEYWORDS（{exc}）。\n"
        f"请确认 danmaku_censor.py 与 beep_filter.py 放在同一目录。"
    )

# ── 画面/文本侧扩展：汉字（含财务体、繁体）与数字的交叉组合 ──
_CN_6 = ("六", "陆", "陸", "6")
_CN_4 = ("四", "肆", "4")
_CN_8 = ("八", "捌", "8")
_CN_9 = ("九", "玖", "9")
_CN_10 = ("十", "拾")


def _build_visual_keywords():
    out = []
    for a in _CN_6:
        for b in _CN_4:
            out.append(a + b)                 # 六四 / 陆肆 / 陸肆 / 六4 / 6肆 …
        for t in _CN_10:
            for b in _CN_4:
                out.append(a + t + b)         # 六十四 / 陆拾肆 / 6拾4 …
        for t in _DATE_INFIX:
            for b in _CN_4:
                out.append(a + t + b)         # 6月4 / 六月四 这类日期写法
    for a in _CN_8:
        for b in _CN_9:
            out.append(a + b)                 # 八九 / 捌玖 / 八9 / 8玖 …
        for t in _CN_10:
            for b in _CN_9:
                out.append(a + t + b)         # 八十九 / 捌拾玖 / 8拾九 …
        for t in _DATE_INFIX:
            for b in _CN_9:
                out.append(a + t + b)         # 8月9 / 八月九
    return out


# 可能夹在数字之间、被用来"断开"敏感数字的分隔符
SEPARATORS = ".,。，、·•‧∙-–—_/\\|:：;；~～'’\"“”*#@&+=^%$"
_SEPARATOR_TABLE = {ord(c): None for c in SEPARATORS}

# 日期写法中间那个"月"：机器审核做数字提取时通常也会把它当噪声跳过，
# 所以 6月4 / 8月9 这类日期形式一并覆盖（宁可多删，不放过）。
_DATE_INFIX = ("月",)


def normalize(text: str) -> str:
    """把正文归一化成便于比对的形式（全角→半角、去空白、去分隔符）。"""
    t = unicodedata.normalize("NFKC", text)
    t = re.sub(r"\s+", "", t)
    return t.translate(_SEPARATOR_TABLE)


# 最终生效的关键词（长的排前面，便于报告命中的是哪个写法）
CLEAN_KEYWORDS = sorted(
    {normalize(kw) for kw in (list(AUDIO_KEYWORDS) + _build_visual_keywords()) if normalize(kw)},
    key=lambda x: -len(x),
)

OVERRIDE_RE = re.compile(r"(?<!\\)\{[^}]*\}")
# 注意 (?<!\\) ：xml 转换时会把弹幕正文里真正的花括号转义成 \{ \}，
# 那种不是特效指令。若不排除，"{六四}" 这类正文会被当成指令剥掉从而漏审。


def strip_overrides(text: str) -> str:
    """剥掉 ASS 特效指令 {\\move(...)}、{\\alpha...} 等，只留真正的弹幕正文。"""
    return OVERRIDE_RE.sub("", text)


def split_dialogue(line: str):
    """把 Dialogue 行拆成 (前缀, 正文)。

    ASS 的 Events 行固定是「9 个逗号字段 + Text」，而正文本身可以含逗号，
    所以只按前 9 个逗号切分，绝不能对整行直接做关键词匹配
    （时间戳、坐标里出现 64/89 就误杀了）。
    """
    head, sep, body = line.partition(":")
    if sep != ":" or head.strip() != "Dialogue":
        return None, None
    fields = body.split(",", 9)
    if len(fields) < 10:
        return None, None
    prefix = head + ":" + ",".join(fields[:9]) + ","
    return prefix, fields[9]


def match_keyword(body: str):
    """返回命中的关键词（归一化后的形式），没有命中则返回 None。"""
    clean = normalize(body)
    if not clean:
        return None
    for kw in CLEAN_KEYWORDS:
        if kw in clean:
            return kw
    return None


def censor_file(path: str, out_path: str, preview: int, verbose: bool):
    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        lines = fh.read().splitlines()

    kept = []
    removed = []          # (行号, 关键词, 正文)
    total_dialogue = 0

    for idx, line in enumerate(lines):
        if not line.startswith("Dialogue:"):
            kept.append(line)
            continue
        total_dialogue += 1
        prefix, text = split_dialogue(line)
        if prefix is None:
            kept.append(line)
            continue
        body = strip_overrides(text)
        hit = match_keyword(body)
        if hit:
            removed.append((idx + 1, hit, body.strip()))
        else:
            kept.append(line)

    if verbose:
        print(f"  弹幕正文审查: 共 {total_dialogue} 行，抹除 {len(removed)} 行", end="")
        if removed:
            stat = collections.Counter(kw for _, kw, _ in removed)
            detail = "、".join(f"{k} ×{v}" for k, v in stat.most_common())
            print(f"（命中：{detail}）")
            for _, kw, body in removed[:max(0, preview)]:
                sample = body if len(body) <= 30 else body[:30] + "…"
                print(f"    命中「{kw}」→ 已抹除: {sample}")
        else:
            print("（未命中任何目标关键词）")

    if out_path:
        tmp = out_path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(kept) + "\n")
        os.replace(tmp, out_path)

    return len(removed), total_dialogue


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="审查 ASS 弹幕正文：命中敏感数字（64 / 89 的各种视觉写法）的整行弹幕直接抹除",
    )
    ap.add_argument("input", nargs="?", help="待审查的 .ass 文件")
    ap.add_argument("-o", "--output", help="输出路径；默认原地改写输入文件")
    ap.add_argument("--preview", type=int, default=3,
                    help="最多打印几条被抹除的样例（默认 3，0 表示不打印）")
    ap.add_argument("--dry-run", action="store_true", help="只统计不写文件")
    ap.add_argument("--list-keywords", action="store_true",
                    help="只打印最终生效的关键词清单（便于核对覆盖面），不处理文件")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    if args.list_keywords:
        print(f"基础（来自 beep_filter.TARGET_KEYWORDS，音频侧同源）{len(AUDIO_KEYWORDS)} 个：")
        print("  " + "、".join(AUDIO_KEYWORDS))
        print(f"\n归一化后实际生效的关键词共 {len(CLEAN_KEYWORDS)} 个：")
        for i in range(0, len(CLEAN_KEYWORDS), 8):
            print("  " + "、".join(CLEAN_KEYWORDS[i:i + 8]))
        return 0

    if not args.input:
        ap.error("需要给出待审查的 .ass 文件（或使用 --list-keywords）")
    if not os.path.isfile(args.input):
        raise SystemExit(f"找不到文件: {args.input}")

    out = args.output or args.input
    if args.dry_run:
        out = ""

    censor_file(args.input, out, args.preview, not args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
