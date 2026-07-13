# 🎯 Video Beep Filter

**自动检测视频音频中包含有“2^6”且相加和为153的两种涉政敏感数字语音，并用「哔——」声替代，帮助录播视频过审。**

[![Python 3.10+](https://img.shields.io/badge/python-3.10%2B-blue)](https://www.python.org/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-required-green)](https://ffmpeg.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

---

## 📋 目录

- [技术栈](#-技术栈)
- [实现原理](#-实现原理)
- [前置依赖](#-前置依赖)
- [安装](#-安装)
- [快速开始](#-快速开始)
- [详细用法](#-详细用法)
- [参数说明](#-参数说明)
- [检测的目标数字](#-检测的目标数字)
- [工作流程详解](#-工作流程详解)
- [性能说明](#-性能说明)
- [常见问题](#-常见问题)
- [项目结构](#-项目结构)

---

## 🛠 技术栈

| 组件 | 技术 | 用途 |
|------|------|------|
| **语音识别** | [OpenAI Whisper](https://github.com/openai/whisper) (原版, tiny/base/small/medium/large) | 中文语音转文字，获取逐字时间戳 |
| **深度学习框架** | [PyTorch](https://pytorch.org/) (CPU 版 ~500MB) | Whisper 模型推理后端 |
| **音频/视频处理** | [FFmpeg](https://ffmpeg.org/) | 音频提取、滤镜处理、视频封装 |
| **编程语言** | Python 3.8+ | 胶水脚本，编排整个工作流 |

### 为什么不使用 faster-whisper？

`faster-whisper` 虽然推理速度更快，但其模型托管在 HuggingFace Hub 上。在中国大陆网络环境下，HuggingFace 的镜像站存在兼容性问题，导致模型下载频繁失败。原版 `openai-whisper` 从 OpenAI CDN 下载模型，在国内网络下更稳定可靠。

---

## 🔬 实现原理

```
┌─────────────────────────────────────────────────────────────────────┐
│                         输入视频 (FLV/MP4/MKV)                       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 1: 音频提取 (ffmpeg)                                          │
│  命令: ffmpeg -i input.flv -vn -acodec pcm_s16le -ar 16000 -ac 1   │
│  输出: 16kHz 单声道 WAV                                             │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 2: 语音识别 (OpenAI Whisper)                                   │
│  模型: whisper.load_model("base", device="cpu")                     │
│  配置: language="zh", word_timestamps=True, beam_size=5             │
│  输出: 带逐字时间戳的识别文本 segments                                │
│        每个 segment 包含: start, end, text, words[]                  │
│        每个 word 包含: word, start, end, probability                 │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 3: 关键词定位                                                  │
│  在识别结果中搜索 12 种目标关键词变体:                                │
│    "六四", "六十四", "零点六四", "64", "6 4", "六毛四"               │
│    "八九", "八十九", "零点八九", "89", "8 9", "八毛九"               │
│  匹配策略:                                                          │
│    ① 优先用逐字时间戳滑动窗口精确定位起止时间                        │
│    ② 降级使用整个 segment 的时间范围                                 │
│  输出: [(start1, end1), (start2, end2), ...]  (合并重叠区间)         │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 4: 哔声替代 (ffmpeg filter_complex)                           │
│  滤镜链:                                                            │
│    [0:a]volume=enable='between(t,s1,e1)+...':volume=0[a_muted];     │
│    sine=f=880:d=0.8:sr=48000[b0_raw];                               │
│    [b0_raw]aformat=channel_layouts=stereo[b0_st];                   │
│    [b0_st]adelay=delay_ms|delay_ms[b0];                             │
│    ...                                                              │
│    [a_muted][b0][b1]amix=inputs=N:duration=first[audio_out]         │
│  效果:                                                              │
│    • 目标时间段原音频 → 静音                                        │
│    • 同一时间段叠加 880Hz 哔声（≈电视消音效果）                       │
│    • 视频流直接复制 (-c:v copy)，无画质损失                          │
│    • 音频重新编码为 AAC 192kbps                                     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      输出视频 (FLV/MP4)                              │
│               原画质 + 目标数字被哔声覆盖                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📦 前置依赖

| 软件 | 版本要求 | 说明 |
|------|---------|------|
| **FFmpeg** | ≥ 4.0 | 需在系统 PATH 中，或通过 `--ffmpeg-path` 指定路径 |
| **FFprobe** | 随 FFmpeg 附带 | 用于获取音频元信息 |
| **Python** | ≥ 3.8 | 脚本运行环境 |
| **PyTorch** | CPU 版即可 (~500MB) | 自动通过 pip 安装 |

> ⚠️ **磁盘空间注意**：`openai-whisper` 及其依赖 PyTorch 约占用 **500MB** 磁盘空间。Whisper 模型文件（`base` ~150MB）在首次运行时自动下载并缓存。

---

## 🚀 安装

### 1. 安装 FFmpeg

```powershell
# 使用 Chocolatey（推荐）
choco install ffmpeg

# 或手动下载: https://www.gyan.dev/ffmpeg/builds/
# 解压后将其 bin 目录加入系统 PATH
```

验证安装：

```bash
ffmpeg -version
```

### 2. 下载本工具

```bash
git clone git@github.com:AnsonSkywalker/video-beep-filter.git
cd video-beep-filter
```

### 3. 安装 Python 依赖（自动）

首次运行脚本时会自动安装缺失的依赖：

```bash
python beep_filter.py "D:\视频.flv"
```

也可以手动安装：

```bash
pip install openai-whisper
```

---

## ⚡ 快速开始

### 基础用法

```bash
python beep_filter.py "D:\视频.flv"
```

脚本会自动：
1. 检查并安装 `openai-whisper`（首次运行需要）
2. 下载 Whisper `base` 模型（~150MB，**首次下载后缓存**）
3. 提取音频 → 语音识别 → 查找数字 → 哔声处理
4. 生成 `录制_消音版.flv`

### 先预览再处理（推荐）

```bash
python beep_filter.py "D:\视频.flv" --dry-run
```

`--dry-run` 模式**只显示识别结果**，不修改视频。确认能正确检测到目标数字后再去掉此参数正式处理。

### 使用更快的模型

```bash
python beep_filter.py "D:\视频.flv" --model-size tiny
```

`tiny` 模型约 70MB，识别速度比 `base` 快 2-3 倍，准确率在清晰录音中足够使用。

---

## 📖 详细用法

### 批量处理多个视频（使用 shell 循环）

**PowerShell：**
```powershell
Get-ChildItem "D:\录播" -Filter "*.flv" | ForEach-Object {
    python beep_filter.py $_.FullName
}
```

**CMD：**
```cmd
for %i in (D:\录播\*.flv) do python beep_filter.py "%i"
```

### 自定义输出路径

```bash
python beep_filter.py "D:\视频.flv" -o "D:\已处理\过审版.flv"
```

### 调整哔声参数

```bash
# 更高频的哔声（1000Hz），更像电视消音
python beep_filter.py "D:\视频.flv" --beep-freq 1000

# 延长哔声持续时间
python beep_filter.py "D:\视频.flv" --beep-duration 1.2

# 增加数字前后消音范围
python beep_filter.py "D:\视频.flv" --padding 0.5
```

### 调试：保留中间音频文件

```bash
python beep_filter.py "D:\视频.flv" --keep-wav
```

会在输出目录生成同名的 `.wav` 文件，方便检查音频提取是否正常。

---

## 🔧 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `input` | (必填) | 输入视频文件路径（支持 FLV/MP4/AVI/MKV 等） |
| `-o, --output` | 自动生成 | 输出文件路径，默认 `原文件名_消音版.扩展名` |
| `--model-size` | `base` | Whisper 模型大小：`tiny`(最快) / `base` / `small` / `medium` / `large` |
| `--beep-freq` | `880` | 哔声频率 (Hz)，880 类似电视消音效果 |
| `--beep-duration` | `0.8` | 哔声持续秒数，自动截断不超过区间长度 |
| `--padding` | `0.3` | 目标数字前后额外消音时长 (秒) |
| `--dry-run` | `false` | 仅显示识别结果，不执行音频处理 |
| `--keep-wav` | `false` | 保留中间提取的 WAV 音频文件 |
| `--ffmpeg-path` | 自动查找 | 指定 ffmpeg 可执行文件路径 |
| `--ffprobe-path` | 自动查找 | 指定 ffprobe 可执行文件路径 |

---

## 🎯 检测的目标数字

脚本会自动匹配以下 **12 种关键词变体**，涵盖各种可能的读音和识别结果：

| 目标 | 匹配关键词 | 预期场景 |
|------|-----------|---------|
| **64** | `六四`、`六十四`、`零点六四`、`零 点 六 四` | "支付宝到账零点六四元" |
| **64** | `64`、`6 4` | 数字直接读出 |
| **64** | `六毛四` | 口语化表达 |
| **89** | `八九`、`八十九`、`零点八九`、`零 点 八 九` | "支付宝到账零点八九元" |
| **89** | `89`、`8 9` | 数字直接读出 |
| **89** | `八毛九` | 口语化表达 |

---

## 🔄 工作流程详解

### Step 1: 音频提取

```bash
ffmpeg -i input.flv -vn -acodec pcm_s16le -ar 16000 -ac 1 -y audio.wav
```

- **格式**: WAV (PCM 16-bit 有符号)
- **采样率**: 16kHz（Whisper 最优输入）
- **声道**: 单声道（Whisper 推荐）

### Step 2: 中文语音识别

使用原版 OpenAI Whisper，加载指定大小的多语言模型（`tiny` / `base` 等），以中文模式运行识别，启用 `word_timestamps=True` 获取逐字时间戳。

关键参数：
- `language="zh"` — 强制中文识别
- `beam_size=5` — 波束搜索宽度
- `word_timestamps=True` — 逐字时间戳
- `condition_on_previous_text=False` — 避免上下文偏差

### Step 3: 关键词定位

1. 对每个 segment 的文本，去空格后与所有关键词变体匹配
2. 匹配成功后，优先使用逐字时间戳滑动窗口精确定位
3. 如果逐字匹配失败，降级使用整个 segment 的时间范围
4. 所有命中的区间加上 `--padding` 参数指定的缓冲时间
5. 合并重叠或相邻（<50ms 间隙）的区间

### Step 4: FFmpeg 滤镜处理

核心滤镜链由 Python 动态生成：

```
[0:a]volume=enable='between(t,1.5,2.3)+between(t,5.0,5.8)':volume=0[a_muted];
sine=frequency=880:duration=0.8:sample_rate=48000[b0_raw];
[b0_raw]aformat=channel_layouts=stereo[b0_st];
[b0_st]adelay=1500|1500[b0];
sine=frequency=880:duration=0.8:sample_rate=48000[b1_raw];
[b1_raw]aformat=channel_layouts=stereo[b1_st];
[b1_st]adelay=5000|5000[b1];
[a_muted][b0][b1]amix=inputs=3:duration=first:dropout_transition=0[audio_out]
```

- `volume=enable=...` — 在指定时间段将音量设为 0（静音）
- `sine` — 生成一个正弦波（哔声）
- `aformat=channel_layouts=stereo` — 确保声道数与原音频匹配
- `adelay=ms|ms` — 将哔声延迟到目标时间点
- `amix` — 将所有音轨混合为一路

视频流使用 `-c:v copy` 直接复制，**不重新编码**，所以处理速度极快且无画质损失。

---

## ⚙️ 性能说明

| 模型 | 磁盘占用 | 相对速度 | 推荐场景 |
|------|---------|---------|---------|
| `tiny` | ~70 MB | 🚀 最快 | 清晰录音，快速处理 |
| `base` | ~150 MB | ⚡ 较快 | **默认，平衡速度和准确率** |
| `small` | ~500 MB | 🐢 较慢 | 背景噪音较大的场景 |
| `medium` | ~1.5 GB | 🐌 慢 | 需要极高准确率 |
| `large` | ~3 GB | 🐢 最慢 | 复杂音频场景 |

> ⚡ **GPU 加速**：如果您有 NVIDIA GPU，可以安装 CUDA 版 PyTorch 获得 3-5 倍加速：
> ```bash
> pip uninstall torch -y
> pip install torch --index-url https://download.pytorch.org/whl/cu124
> ```
> ⚠️ CUDA 版 PyTorch 约 4.4GB 磁盘空间。

---

## ❓ 常见问题

### Q: 首次运行很慢？

**A:** 首次需要：
1. 下载 Whisper 模型（`base` ~150MB，从 OpenAI CDN 下载）
2. 加载模型到内存

模型会缓存到 `~/.cache/whisper/`，后续无需重复下载。

### Q: 识别不准确（漏检或误检）？

**A:** 尝试以下方案：
- 使用更大的模型：`--model-size small` 或 `--model-size medium`
- 确保音频清晰，无严重背景噪音
- 先用 `--dry-run` 预览识别结果，确认关键词被正确识别
- 如果数字被读作其他表达方式，可以自行在脚本的 `TARGET_KEYWORDS` 列表中追加

### Q: 哔声太短/太长/太尖/太沉？

**A:** 调整参数：

```bash
# 频率：数字越大越尖锐
--beep-freq 1000   # 更尖锐（接近电视消音）
--beep-freq 440    # 更低沉（接近电话忙音）

# 时长：数字越大越长
--beep-duration 0.5  # 更短促
--beep-duration 1.5  # 更长
```

### Q: 处理后的视频文件多大？

**A:** 脚本使用 `-c:v copy` 直接复制视频流，**不重新编码**，考虑到多媒体视频文件体积大小普遍90%以上都来自其图像而不是音频，所以文件大小几乎不变。音频轨从原始格式重新编码为 AAC 192kbps。

### Q: 支持哪些输入格式？

**A:** 任何 FFmpeg 支持的视频格式：FLV、MP4、AVI、MKV、MOV、TS 等。

### Q: 可以处理直播流或网络视频吗？

**A:** 可以，直接传入 URL 即可：

```bash
python beep_filter.py "https://example.com/live.stream.flv"
```

但需要稳定的网络连接。

---

## 📁 项目结构

```
video-beep-filter/
├── beep_filter.py      # 主脚本（核心工作流）
├── README.md           # 本文件
├── .gitignore          # Git 忽略规则
└── LICENSE             # 许可证（MIT）
```

---

## 📜 许可证

本项目基于 MIT 许可证开源。详见 [LICENSE](LICENSE) 文件。

---
*Vibe Coding Alert: 99.9% of the code in this repository was generated by Reasonix. Thanks to DeepSeek.*

*Made with ❤️ for the live streaming archiving community.*
