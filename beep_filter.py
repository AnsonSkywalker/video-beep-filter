#!/usr/bin/env python3
"""
FLV 视频自动消音工具 —— 支付宝收款语音消音器
================================================
自动检测视频音频中 "六四""八九""64""89" 等数字语音，
用「哔——」声替代，帮助视频过审。

工作流程：
  1. 用 ffmpeg 提取音频为临时 WAV
  2. 用 OpenAI Whisper 做中文语音识别，获取逐字时间戳
  3. 定位目标数字的起止时间
  4. 用 ffmpeg 滤镜链：原音频对应段静音 + 叠加哔声
  5. 输出最终视频

依赖（脚本会自动安装 Python 包）：
  - ffmpeg / ffprobe（需已安装在系统 PATH 中）
  - Python 3.8+
  - openai-whisper（自动安装，含 PyTorch CPU 版约 800MB）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import List, Tuple


# ─── 目标数字关键词（中文语音识别可能的各种形态） ──────────────────────────
# whisper 中文识别会将 "0.64" 读为 "零点六四"，"0.89" 读为 "零点八九"
TARGET_KEYWORDS = [
    # "六四" 相关
    "六四", "六十四",
    "零点六四", "零 点 六 四",
    "6 4", "64",
    # "八九" 相关
    "八九", "八十九",
    "零点八九", "零 点 八 九",
    "8 9", "89",
    # 口语化表达
    "六毛四", "八毛九",
]

# ffmpeg 查找路径
FFMPEG_DEFAULT = "ffmpeg"
FFPROBE_DEFAULT = "ffprobe"


# ═══════════════════════════════════════════════════════════════════════
#  辅助函数
# ═══════════════════════════════════════════════════════════════════════

def find_executable(name: str, hint: str | None = None) -> str:
    """查找可执行文件，优先使用 hint（用户指定的路径），再在 PATH 中查找。"""
    if hint and hint != name:
        try:
            subprocess.run([hint, "-version"], capture_output=True, check=True)
            return hint
        except (subprocess.SubprocessError, FileNotFoundError):
            pass
    # 在 PATH 中查找
    for candidate in [name, f"{name}.exe"]:
        try:
            r = subprocess.run(
                ["where", candidate], capture_output=True, text=True, shell=True
            )
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip().split("\n")[0]
        except Exception:
            pass
    # 备选常见路径
    candidates = [
        Path(f"D:/ffmpeg-2025-04-14-git-3b2a9410ef-full_build/bin/{name}.exe"),
        Path(f"C:/ffmpeg/bin/{name}.exe"),
        Path(f"C:/Program Files/ffmpeg/bin/{name}.exe"),
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    return name  # 最后尝试直接调用


def get_audio_duration(ffprobe_path: str, video_path: str) -> float:
    """用 ffprobe 获取音频时长（秒）。"""
    try:
        r = subprocess.run(
            [ffprobe_path, "-v", "quiet", "-show_entries", "stream=duration",
             "-select_streams", "a:0", "-of", "json", video_path],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(r.stdout)
        streams = data.get("streams", [])
        if streams and streams[0].get("duration"):
            return float(streams[0]["duration"])
    except Exception:
        pass
    # 降级：format duration
    try:
        r = subprocess.run(
            [ffprobe_path, "-v", "quiet", "-show_entries", "format=duration",
             "-of", "json", video_path],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(r.stdout)
        if data.get("format", {}).get("duration"):
            return float(data["format"]["duration"])
    except Exception:
        pass
    return 0.0


def merge_intervals(intervals: List[Tuple[float, float]]) -> List[Tuple[float, float]]:
    """合并重叠或相邻（<50ms 间隙）的时间区间。"""
    if not intervals:
        return []
    sorted_iv = sorted(intervals, key=lambda x: x[0])
    merged = [list(sorted_iv[0])]
    for start, end in sorted_iv[1:]:
        if start <= merged[-1][1] + 0.05:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(round(s, 3), round(e, 3)) for s, e in merged]


def format_time(seconds: float) -> str:
    """将秒数格式化为 HH:MM:SS.mmm"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def print_banner():
    print()
    print("=" * 60)
    print("  🎯  FLV 视频自动消音工具")
    print("  自动检测「六四」「八九」等数字语音 → 哔声替代")
    print("=" * 60)


# ═══════════════════════════════════════════════════════════════════════
#  Step 1：语音识别
# ═══════════════════════════════════════════════════════════════════════

def extract_audio(ffmpeg_path: str, video_path: str, output_wav: str):
    """用 ffmpeg 提取音频为 16kHz 单声道 WAV（whisper 推荐格式）。"""
    cmd = [
        ffmpeg_path,
        "-i", video_path,
        "-vn",
        "-acodec", "pcm_s16le",
        "-ar", "16000",
        "-ac", "1",
        "-y",
        output_wav,
    ]
    print(f"  🎵 提取音频 → {os.path.basename(output_wav)}")
    subprocess.run(cmd, check=True, capture_output=True)


def transcribe_audio(model_size: str, audio_path: str) -> list:
    """用 OpenAI Whisper 进行语音识别，返回带逐字时间戳的 segments。"""
    import whisper

    print(f"  🧠 加载 Whisper 模型（{model_size}）...")
    start_ts = time.time()

    device = "cpu"
    try:
        import torch
        if torch.cuda.is_available():
            device = "cuda"
    except Exception:
        pass

    model = whisper.load_model(model_size, device=device)
    load_time = time.time() - start_ts
    print(f"  ✅ 模型加载完成，用时 {load_time:.1f}s")

    audio_mb = os.path.getsize(audio_path) / 1024 / 1024
    print(f"  🔍 识别中...（音频 {audio_mb:.1f} MB）")
    transcribe_start = time.time()

    result = model.transcribe(
        audio_path,
        language="zh",
        word_timestamps=True,
        beam_size=5,
        condition_on_previous_text=False,
        verbose=False,
    )

    elapsed = time.time() - transcribe_start
    segments = result.get("segments", [])
    print(f"  ✅ 识别完成，用时 {elapsed:.1f}s，共 {len(segments)} 个片段")
    return segments


def find_target_segments(
    segments: list, padding: float
) -> Tuple[List[Tuple[float, float]], List[str]]:
    """
    从识别结果中找出包含目标数字的片段及时间区间。

    策略：
      - 在 segment 文本中匹配关键词
      - 若能获取逐字时间戳（words），用其精确定位关键词的起止
      - 否则使用整个 segment 的时间 + padding

    返回: (合并后的时间区间列表, 匹配到的上下文文本列表)
    """
    hits: List[Tuple[float, float]] = []
    contexts: List[str] = []

    print(f"\n  🔎 搜索目标数字: {TARGET_KEYWORDS}")
    print(f"  {'─' * 60}")

    for seg in segments:
        text = seg.get("text", "").strip()
        if not text:
            continue

        # 检查是否包含关键词（去空格后匹配）
        text_clean = re.sub(r'\s+', '', text)
        matched_kw: str | None = None
        for kw in TARGET_KEYWORDS:
            kw_clean = re.sub(r'\s+', '', kw)
            if kw_clean in text_clean:
                matched_kw = kw
                break

        if not matched_kw:
            continue

        # 尝试用逐字时间戳精确定位
        kw_clean = re.sub(r'\s+', '', matched_kw)
        found_exact = False

        words = seg.get("words")
        if words:
            # 对于多字关键词，在 words 列表中滑动窗口匹配
            kw_chars = list(kw_clean)
            for i in range(len(words) - len(kw_chars) + 1):
                window_text = ''.join(
                    re.sub(r'\s+', '', w.get("word", "")) for w in words[i:i + len(kw_chars)]
                )
                if window_text == kw_clean:
                    start = max(0, words[i].get("start", 0) - padding)
                    end = words[i + len(kw_chars) - 1].get("end", 0) + padding
                    hits.append((start, end))
                    contexts.append(text[:80])
                    print(f"  ⚡ 「{matched_kw}」→ {format_time(start)} → {format_time(end)}"
                          f"  (原文: 「{text[:50]}」)")
                    found_exact = True
                    break

            # 如果精确匹配没找到，可能是一个 word 包含整个关键词
            if not found_exact:
                for w in words:
                    w_clean = re.sub(r'\s+', '', w.get("word", ""))
                    if kw_clean in w_clean:
                        start = max(0, w.get("start", 0) - padding)
                        end = w.get("end", 0) + padding
                        hits.append((start, end))
                        contexts.append(text[:80])
                        print(f"  ⚡ 「{matched_kw}」→ {format_time(start)} → {format_time(end)}"
                              f"  (原文: 「{text[:50]}」)")
                        found_exact = True
                        break

        if not found_exact:
            # 降级：使用整个 segment 的时间
            start = max(0, seg.get("start", 0) - padding)
            end = seg.get("end", 0) + padding
            hits.append((start, end))
            contexts.append(text[:80])
            print(f"  ⚡ 「{matched_kw}」→ {format_time(start)} → {format_time(end)}"
                  f"  (原文: 「{text[:50]}」)")

    if not hits:
        print(f"  {'─' * 60}")
        print(f"  ✅ 未检测到目标数字，无需处理。")
        return [], []

    # 合并重叠区间
    merged = merge_intervals(hits)
    print(f"  {'─' * 60}")
    print(f"  📊 合并后共 {len(merged)} 个需处理区间:")
    for i, (s, e) in enumerate(merged, 1):
        print(f"     [{i}] {format_time(s)} → {format_time(e)}  (时长 {e-s:.2f}s)")

    return merged, contexts


# ═══════════════════════════════════════════════════════════════════════
#  Step 2：ffmpeg 处理 —— 哔声替代
# ═══════════════════════════════════════════════════════════════════════

def build_beep_filter(
    intervals: List[Tuple[float, float]],
    beep_freq: int,
    beep_duration: float,
    sample_rate: int = 48000,
) -> str:
    """
    构建 ffmpeg filter_complex 字符串。

    策略：
      - 原音频的指定区间静音
      - 在每个区间叠加哔声（sine + adelay）
      - 使用 amix 混合

    参数:
      intervals:  [(start_sec, end_sec), ...]
      beep_freq:  哔声频率 Hz
      beep_duration: 哔声持续时间秒
      sample_rate: 音频采样率（匹配原音频）
    """
    if not intervals:
        return ""

    filters: list[str] = []

    # 1. 对原音频做区间静音
    enable_expr = "+".join(
        f"between(t,{s},{e})" for s, e in intervals
    )
    filters.append(
        f"[0:a]volume=enable='{enable_expr}':volume=0[a_muted]"
    )

    # 2. 为每个区间生成哔声并延迟到位
    beep_refs: list[str] = []
    for i, (start, end) in enumerate(intervals):
        seg_duration = end - start
        beep_len = min(seg_duration, beep_duration)
        delay_ms = int(start * 1000)
        tag = f"b{i}"

        # 生成立体声哔声（避免声道不匹配）
        filters.append(
            f"sine=frequency={beep_freq}:duration={beep_len}:sample_rate={sample_rate}[{tag}_raw]"
        )
        # 转为立体声（与原始音频声道数匹配）
        filters.append(
            f"[{tag}_raw]aformat=channel_layouts=stereo[{tag}_st]"
        )
        # 延迟到目标时间
        filters.append(
            f"[{tag}_st]adelay={delay_ms}|{delay_ms}[{tag}]"
        )
        beep_refs.append(f"[{tag}]")

    # 3. 混合：静音后的原音频 + 所有哔声
    all_inputs = "[a_muted]" + "".join(beep_refs)
    n_beeps = len(beep_refs)
    filters.append(
        f"{all_inputs}amix=inputs={1 + n_beeps}:duration=first:dropout_transition=0[audio_out]"
    )

    return "; ".join(filters)


def process_video(
    ffmpeg_path: str,
    ffprobe_path: str,
    input_path: str,
    output_path: str,
    intervals: List[Tuple[float, float]],
    beep_freq: int,
    beep_duration: float,
    dry_run: bool = False,
):
    """使用 ffmpeg 处理视频。"""
    if not intervals:
        print("\n  📋 无需处理，直接复制视频...")
        cmd = [
            ffmpeg_path, "-i", input_path,
            "-c", "copy", "-y", output_path,
        ]
        if not dry_run:
            subprocess.run(cmd, check=True)
        else:
            print(f"  [DRY-RUN] {' '.join(cmd)}")
        return

    # 获取原音频采样率（用于生成匹配的哔声）
    sample_rate = 48000  # 默认
    try:
        r = subprocess.run(
            [ffprobe_path,
             "-v", "quiet",
             "-show_entries", "stream=sample_rate",
             "-select_streams", "a:0",
             "-of", "json",
             input_path],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(r.stdout)
        streams = data.get("streams", [])
        if streams and streams[0].get("sample_rate"):
            sample_rate = int(streams[0]["sample_rate"])
    except Exception:
        pass

    filter_complex = build_beep_filter(intervals, beep_freq, beep_duration, sample_rate)

    print(f"\n  🔧 采样率: {sample_rate} Hz")
    print(f"  🔧 滤镜链预览:")
    for line in filter_complex.split("; "):
        print(f"    {line}")

    cmd = [
        ffmpeg_path,
        "-i", input_path,
        "-filter_complex", filter_complex,
        "-map", "0:v",
        "-map", "[audio_out]",
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-y",
        output_path,
    ]

    print(f"\n  🚀 开始处理...")
    print(f"  输出: {output_path}")

    if dry_run:
        print(f"\n  [DRY-RUN] 命令:")
        print(f"    {' '.join(cmd)}")
        return

    try:
        print(f"  ⏳ ffmpeg 处理中...")
        subprocess.run(cmd, check=True)
        print(f"\n  ✅ 处理完成！输出文件: {output_path}")
    except subprocess.CalledProcessError as e:
        print(f"\n  ❌ ffmpeg 处理失败 (code={e.returncode})")
        sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════
#  依赖管理
# ═══════════════════════════════════════════════════════════════════════

def ensure_deps():
    """检查并自动安装 openai-whisper 等依赖。"""
    missing = []
    try:
        import whisper  # noqa
    except ImportError:
        missing.append("openai-whisper")

    if not missing:
        return True  # 依赖已就绪

    print("=" * 60)
    print(f"📦 安装依赖: {', '.join(missing)}")
    print("=" * 60)
    print("  正在通过 pip 安装（可能需要 5-10 分钟，需下载约 800MB 的 PyTorch）...")

    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "openai-whisper", "--quiet"],
            check=True, timeout=600,
        )
    except subprocess.CalledProcessError as e:
        print(f"\n  ❌ 安装失败: {e}")
        print("  请手动运行: pip install openai-whisper")
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"\n  ❌ 安装超时，请手动运行: pip install openai-whisper")
        sys.exit(1)

    print("✅ 依赖安装完成\n")
    return False  # 需要重启进程以使新安装的包生效


# ═══════════════════════════════════════════════════════════════════════
#  CLI
# ═══════════════════════════════════════════════════════════════════════

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="FLV 视频自动消音工具 —— 自动检测「六四」「八九」等数字语音并用哔声替代",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "使用示例:\n"
            "  python beep_filter.py D:\\视频\\录制.flv\n"
            "  python beep_filter.py D:\\视频\\录制.flv -o 消音版.flv --model-size small\n"
            "  python beep_filter.py D:\\视频\\录制.flv --dry-run    # 仅查看识别结果\n"
            "  python beep_filter.py D:\\视频\\录制.flv --padding 0.3\n"
        ),
    )
    parser.add_argument("input", help="输入视频文件路径（支持 FLV/MP4/AVI/MKV 等）")
    parser.add_argument("-o", "--output", help="输出文件路径（默认: 输入文件名_消音版.扩展名）")
    parser.add_argument("--ffmpeg-path", default=FFMPEG_DEFAULT, help="ffmpeg 路径")
    parser.add_argument("--ffprobe-path", default=FFPROBE_DEFAULT, help="ffprobe 路径")
    parser.add_argument("--model-size", default="base",
                        help="Whisper 模型大小: tiny / base / small / medium / large（默认 base，tiny 最快）")
    parser.add_argument("--beep-freq", type=int, default=880,
                        help="哔声频率 Hz（默认 880，类似电视消音效果）")
    parser.add_argument("--beep-duration", type=float, default=0.8,
                        help="哔声持续时间秒（默认 0.8）")
    parser.add_argument("--padding", type=float, default=0.3,
                        help="数字前后额外消音时长秒（默认 0.3）")
    parser.add_argument("--dry-run", action="store_true",
                        help="仅显示识别结果，不处理音频")
    parser.add_argument("--keep-wav", action="store_true",
                        help="保留中间 WAV 文件（调试用）")
    return parser.parse_args(argv)


# ═══════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    args = parse_args()
    print_banner()

    # ── 检查 ffmpeg ──
    ffmpeg = find_executable("ffmpeg", args.ffmpeg_path)
    ffprobe = find_executable("ffprobe", args.ffprobe_path)
    print(f"\n  🔧 ffmpeg:  {ffmpeg}")
    print(f"  🔧 ffprobe: {ffprobe}")

    # ── 验证 ──
    try:
        subprocess.run([ffmpeg, "-version"], capture_output=True, check=True)
    except Exception:
        print(f"\n  ❌ ffmpeg 不可用！请先安装 ffmpeg 并加入 PATH。")
        sys.exit(1)

    input_path = Path(args.input)
    if not input_path.is_file():
        print(f"\n  ❌ 输入文件不存在: {input_path}")
        sys.exit(1)
    print(f"  📁 输入:   {input_path}")

    # ── 输出路径 ──
    if args.output:
        output_path = Path(args.output)
    else:
        stem = re.sub(r'[<>:"/\\|?*]', '_', input_path.stem)
        output_path = input_path.with_name(f"{stem}_消音版{input_path.suffix}")
    print(f"  📁 输出:   {output_path}")

    # ── 检查依赖 ──
    print(f"\n  📦 检查 Python 依赖...")
    ready = ensure_deps()
    if not ready:
        # 依赖刚安装完，需要重启进程
        print("  🔄 重启进程以加载新安装的依赖...")
        os.execv(sys.executable, [sys.executable] + sys.argv)
        # execv 不返回

    # ── 创建临时目录 ──
    with tempfile.TemporaryDirectory(prefix="beep_filter_") as tmp_dir:
        wav_path = os.path.join(tmp_dir, "audio.wav")

        # ── Step 1: 提取音频 ──
        extract_audio(ffmpeg, str(input_path), wav_path)

        # ── Step 2: 语音识别 ──
        segments = transcribe_audio(args.model_size, wav_path)

        # ── 显示完整识别文本 ──
        print(f"\n  📜 识别文本:")
        print(f"  {'─' * 60}")
        for seg in segments:
            print(f"  [{format_time(seg.get('start', 0))} → {format_time(seg.get('end', 0))}] {seg.get('text', '').strip()}")
        print(f"  {'─' * 60}")

        # ── Step 3: 定位目标 ──
        intervals, contexts = find_target_segments(segments, args.padding)

        # ── Step 4: 处理视频 ──
        process_video(
            ffmpeg, ffprobe,
            str(input_path), str(output_path),
            intervals, args.beep_freq, args.beep_duration,
            dry_run=args.dry_run,
        )

        # ── 保留 WAV ──
        if args.keep_wav:
            import shutil
            shutil.copy2(wav_path, str(output_path.with_suffix(".wav")))
            print(f"  💾 中间音频: {output_path.with_suffix('.wav')}")

    print(f"\n{'=' * 60}")
    if args.dry_run:
        print("  🔍 Dry-Run 完成，以上为识别结果。")
        print("  去掉 --dry-run 即可执行实际处理。")
    else:
        print(f"  ✅ 全部完成！{output_path}")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
