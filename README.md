# 🎯 Video Beep Filter

**自动检测视频音频中包含有"2^6"且相加和为153的两种涉政敏感数字语音，并用「哔——」声替代，帮助录播视频过审。**

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
| **深度学习框架** | [PyTorch](https://pytorch.org/) (支持 CPU / CUDA) | Whisper 模型推理后端 |
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
│  模型: whisper.load_model("base", device="cuda" 或 "cpu")           │
│  配置: language="zh", word_timestamps=True, beam_size=5             │
│  输出: 带逐字时间戳的识别文本 segments                                │
├─────────────────────────────────────────────────────────────────────┤
│  复审模式 (可选):                                                    │
│  使用 --review-model small/medium/large 做大模型二次检测              │
│  两轮区间合并，最大限度减少漏判                                       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 3: 关键词定位                                                  │
│  在识别结果中搜索 14 种目标关键词变体:                                │
│    "六四","六十四","零点六四","64","6 4","六毛四","零 点 六 四"      │
│    "八九","八十九","零点八九","89","8 9","八毛九","零 点 八 九"      │
│  匹配策略（每个 segment 收集全部命中，非仅第一个关键词）：             │
│    ① 逐字时间戳滑动窗口精确匹配                                      │
│    ② 单 word 包含匹配                                               │
│    ③ 整个 segment 时间兜底                                           │
│  输出: [(start1, end1), (start2, end2), ...]  (合并重叠区间)         │
├─────────────────────────────────────────────────────────────────────┤
│  手动模式 (可选):                                                    │
│  跳过 Whisper，交互式输入 HH:MM:SS 时间戳，直接构建滤镜链             │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Step 4: 哔声替代 (ffmpeg filter_complex)                           │
│  滤镜链:                                                            │
│    [0:a]volume=enable='between(t,s1,e1)+...':volume=0[a_muted];     │
│    sine=f=880:d=区间全长:sr=48000[b0_raw];                           │
│    [b0_raw]aformat=channel_layouts=stereo[b0_st];                   │
│    [b0_st]adelay=delay_ms|delay_ms[b0];                             │
│    ...                                                              │
│    [a_muted][b0][b1]amix=inputs=N:duration=first[audio_out]         │
│  效果:                                                              │
│    • 目标时间段原音频 → 静音                                        │
│    • 哔声填满整个消音区间（无静音留白）                               │
│    • 视频流直接复制 (-c:v copy)，无画质损失                          │
│    • 音频重新编码为 AAC 192kbps                                     │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      输出视频 (FLV/MP4)                              │
│               原画质 + 目标数字被哔声覆盖                             │
│         自动模式: 文件名_消音版.flv                                   │
│         手动模式: 文件名_手动修改.flv（保留原标题后缀）                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📦 前置依赖

| 软件 | 版本要求 | 说明 |
|------|---------|------|
| **FFmpeg** | ≥ 4.0 | 需在系统 PATH 中，或通过 `--ffmpeg-path` 指定路径 |
| **FFprobe** | 随 FFmpeg 附带 | 用于获取音频元信息 |
| **Python** | ≥ 3.8 | 脚本运行环境 |
| **PyTorch** | CPU 版即可 (~500MB) | 自动通过 pip 安装；有 NVIDIA GPU 可装 CUDA 版加速 |

> ⚠️ **磁盘空间注意**：`openai-whisper` 及其依赖 PyTorch 约占用 **500MB**（CPU 版）或 **4.4GB**（CUDA 版）。Whisper 模型文件（`base` ~150MB）在首次运行时自动下载并缓存。

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
3. 自动检测 GPU（CUDA）并启用加速
4. 提取音频 → 语音识别 → 查找数字 → 哔声处理
5. 生成 `视频_消音版.flv`

### 先预览再处理（推荐）

```bash
python beep_filter.py "D:\视频.flv" --dry-run
```

`--dry-run` 模式**只显示识别结果**，不修改视频。确认能正确检测到目标数字后再去掉此参数正式处理。

### 双重检测（最大限度减少漏判）

```bash
python beep_filter.py "D:\视频.flv" --review-model small
```

先用 `base` 模型快速扫描，再用 `small` 模型二次检测，合并两轮区间。适合高风险视频。

### 手动补码（审核打回后使用）

```powershell
echo "00:09:31 00:09:34" | python beep_filter.py "D:\视频_消音版.flv" --manual
```

交互式输入审核标注的违规时间点，生成 `视频_消音版_手动修改.flv`。

---

## 📖 详细用法

### 手动消音工作台（`--manual`）

当自动处理后的视频被平台审核打回时，审核方通常会标注具体的违规时间点。使用手动模式按标注补码：

```powershell
python beep_filter.py "D:\视频_消音版.flv" --manual
```

进入交互式工作台：

```
🛠️  手动消音工作台
根据平台审核标注的时间点，手动添加消音区间

格式:  起始时间  结束时间
示例:  00:09:31 00:09:34
输入 q 或 quit 结束，输入 list 查看已添加的区间

> 00:09:31 00:09:34
    ✓ 00:09:31.000 → 00:09:34.000  (时长 3.00s)
> 00:00:42 00:00:55
    ✓ 00:00:42.000 → 00:00:55.000  (时长 13.00s)
> list
    [1] 00:09:31.000 → 00:09:34.000  (3.00s)
    [2] 00:00:42.000 → 00:00:55.000  (13.00s)
> q
```

输出文件：`视频_消音版_手动修改.flv`（保留原标题中的 `_消音版`）。

也支持管道输入（适合批量或脚本调用）：

```powershell
# 从文件读取时间戳
Get-Content timestamps.txt | python beep_filter.py "D:\视频.flv" --manual
```

### 复审模式（`--review-model`）

使用更大的 Whisper 模型做二次检测，与首轮结果合并：

```bash
# small 模型复审（推荐，平衡速度与准确率）
python beep_filter.py "D:\视频.flv" --review-model small

# medium 模型复审（更严格）
python beep_filter.py "D:\视频.flv" --review-model medium

# 指定首轮和复审使用不同模型
python beep_filter.py "D:\视频.flv" --model-size tiny --review-model small
```

复审过程：
1. 首轮用 `--model-size`（默认 `base`）识别 → 定位区间 A
2. 复审用 `--review-model`（如 `small`）识别 → 定位区间 B
3. 合并 A ∪ B → 统一 ffmpeg 处理一次

### GPU 加速

脚本自动检测 NVIDIA GPU 并启用 CUDA 加速。启用后识别速度提升 3-5 倍：

```bash
# 确认 GPU 状态
python -c "import torch; print('CUDA:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')"
```

如果当前安装的是 CPU 版 PyTorch，想启用 GPU 加速：

```bash
pip uninstall torch -y
pip install torch --index-url https://download.pytorch.org/whl/cu124
```

### 批量处理多个视频

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

# 哔声现在会自动填满整个消音区间，--beep-duration 参数仅在极短区间 (<1s) 时作为下限参考
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
| `-o, --output` | 自动生成 | 输出文件路径，默认自动模式 `原文件名_消音版`、手动模式追加 `_手动修改` |
| `--model-size` | `base` | 首轮 Whisper 模型大小：`tiny`(最快) / `base` / `small` / `medium` / `large` |
| `--review-model` | (不启用) | 复审模型大小：`small` / `medium` / `large`。启用后首轮+复审双检测合并区间 |
| `--manual` | `false` | 手动模式：跳过语音识别，交互式输入 HH:MM:SS 时间戳消音 |
| `--beep-freq` | `880` | 哔声频率 (Hz)，880 类似电视消音效果 |
| `--beep-duration` | (已弃用) | 哔声现在自动填满整个消音区间，此参数不再生效 |
| `--padding` | `0.3` | 目标数字前后额外消音时长 (秒) |
| `--dry-run` | `false` | 仅显示识别结果，不执行音频处理 |
| `--keep-wav` | `false` | 保留中间提取的 WAV 音频文件 |
| `--ffmpeg-path` | 自动查找 | 指定 ffmpeg 可执行文件路径 |
| `--ffprobe-path` | 自动查找 | 指定 ffprobe 可执行文件路径 |

---

## 🎯 检测的目标数字

脚本会自动匹配以下 **14 种关键词变体**，涵盖各种可能的读音和识别结果：

| 目标 | 匹配关键词 | 预期场景 |
|------|-----------|---------|
| **64** | `六四`、`六十四`、`零点六四`、`零 点 六 四` | "支付宝到账零点六四元" |
| **64** | `64`、`6 4` | 数字直接读出 |
| **64** | `六毛四` | 口语化表达 |
| **89** | `八九`、`八十九`、`零点八九`、`零 点 八 九` | "支付宝到账零点八九元" |
| **89** | `89`、`8 9` | 数字直接读出 |
| **89** | `八毛九` | 口语化表达 |

匹配策略：
- **同 segment 多关键词**：每个语音片段（segment）不再只匹配第一个关键词，而是遍历全部 14 种变体，收集所有命中
- **关键词去重**：按长度降序排列，短词被子串去重（如"六四"不会在"零点六四"已匹配时重复）
- **三级定位**：逐字时间戳滑动窗口 → 单个 word 包含 → 整个 segment 时间 ±padding 兜底

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

**复审模式**：如果指定了 `--review-model`，会在首轮完成后自动进行第二轮识别（使用更大模型），合并两轮区间结果。

### Step 3: 关键词定位

1. 对每个 segment 的文本，去空格后与所有 14 种关键词变体匹配（**不再只找第一个**）
2. 长关键词优先匹配，短词被子串自动去重，避免重复定位
3. 首级：使用逐字时间戳滑动窗口精确定位
4. 次级：单个 word 包含关键词
5. 末级：整个 segment 的时间范围 ±padding 兜底
6. 所有命中的区间加上 `--padding` 参数指定的缓冲时间
7. 合并重叠或相邻（<50ms 间隙）的区间

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
- `sine` — 生成一个正弦波（哔声），**duration 填满整个消音区间**
- `aformat=channel_layouts=stereo` — 确保声道数与原音频匹配
- `adelay=ms|ms` — 将哔声延迟到目标时间点
- `amix` — 将所有音轨混合为一路

视频流使用 `-c:v copy` 直接复制，**不重新编码**，所以处理速度极快且无画质损失。

---

## ⚙️ 性能说明

### 模型对比

| 模型 | 磁盘占用 | CPU 速度 | CUDA 速度 | 推荐场景 |
|------|---------|---------|-----------|---------|
| `tiny` | ~70 MB | 🚀 最快 | 🚀 极快 | 清晰录音，快速处理 |
| `base` | ~150 MB | ⚡ 较快 | ⚡ 极快 | **默认，平衡速度和准确率** |
| `small` | ~500 MB | 🐢 较慢 | ⚡ 快 | 复审模式首选，背景噪音较大 |
| `medium` | ~1.5 GB | 🐌 慢 | ⚡ 较快 | 需要极高准确率 |
| `large` | ~3 GB | 🐢 最慢 | ⚡ 正常 | 复杂音频场景 |

### GPU 加速（CUDA）

> ⚡ **强烈推荐**：如果您有 NVIDIA GPU（如 RTX 4070 Ti SUPER），安装 CUDA 版 PyTorch 可获得 **3-5 倍加速**：
> ```bash
> pip uninstall torch -y
> pip install torch --index-url https://download.pytorch.org/whl/cu124
> ```
>
> ⚠️ CUDA 版 PyTorch 约 4.4GB 磁盘空间。
>
> 脚本自动检测 GPU 并启用 CUDA，无需额外配置。Triton 相关警告已静默处理（不影响功能）。

### 处理时间参考

以下为 **1 小时视频** 在 RTX 4070 Ti SUPER 上的大致处理时间：

| 模式 | 模型 | 识别耗时 | 滤镜处理 | 总计 |
|------|------|---------|---------|------|
| 标准 | base (CUDA) | ~3 min | ~30 s | ~4 min |
| 复审 | base + small | ~5 min | ~30 s | ~6 min |
| 手动 | (无识别) | 0 | ~30 s | ~30 s |

---

## ❓ 常见问题

### Q: 首次运行很慢？

**A:** 首次需要：
1. 下载 Whisper 模型（`base` ~150MB，从 OpenAI CDN 下载）
2. 加载模型到内存

模型会缓存到 `~/.cache/whisper/`，后续无需重复下载。有 NVIDIA GPU 的话建议安装 CUDA 版 PyTorch。

### Q: 识别不准确（漏检或误检）？

**A:** 尝试以下方案：
- 使用 `--review-model small` 启用双模型复审（最有效）
- 使用更大的模型：`--model-size small` 或 `--model-size medium`
- 先用 `--dry-run` 预览识别结果，确认关键词被正确识别
- 审核打回后使用 `--manual` 手工补码精确时间点
- 如果数字被读作其他表达方式，可以自行在脚本的 `TARGET_KEYWORDS` 列表中追加

### Q: 哔声太短/太长/太尖/太沉？

**A:** 哔声现在会自动填满整个消音区间，不会出现哔声结束后静音留白的情况。频率调整：

```bash
--beep-freq 1000   # 更尖锐（接近电视消音）
--beep-freq 440    # 更低沉（接近电话忙音）
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

### Q: 自动模式和手动模式的文件名有什么区别？

**A:**
| 模式 | 输入 | 输出 |
|------|------|------|
| 自动 | `视频.flv` | `视频_消音版.flv` |
| 手动 | `视频_消音版.flv` | `视频_消音版_手动修改.flv` |

手动模式在原始文件名后追加 `_手动修改`，保留 `_消音版` 等既有后缀。

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
