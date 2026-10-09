# 🎯 Video Beep Filter

**自动检测视频音频中包含有"2^6"且相加和为153的两种涉政敏感数字语音，并用「哔——」声替代，帮助录播视频过审。**

**配套的一键脚本还能在消音之后，把与视频同名的直播弹幕（抖音 ass / B站 xml）硬编码进画面，按来源加平台前缀并统一导出 MP4。**

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
- [弹幕硬编码流水线（一键拆弹_弹幕版.ps1）](#-弹幕硬编码流水线一键拆弹_弹幕版ps1)
- [常见问题](#-常见问题)
- [项目结构](#-项目结构)

---

## 🛠 技术栈

| 组件 | 技术 | 用途 |
|------|------|------|
| **语音识别** | [OpenAI Whisper](https://github.com/openai/whisper) (原版, tiny/base/small/medium/large) | 中文语音转文字，获取逐字时间戳 |
| **深度学习框架** | [PyTorch](https://pytorch.org/) (支持 CPU / CUDA) | Whisper 模型推理后端 |
| **音频/视频处理** | [FFmpeg](https://ffmpeg.org/) | 音频提取、滤镜处理、视频封装 |
| **弹幕渲染** | [libass](https://github.com/libass/libass)（经 FFmpeg 的 `ass` 滤镜） | 把弹幕字幕烧进画面 |
| **编程语言** | Python 3.8+ | 胶水脚本，编排整个工作流 |
| **批处理编排** | Windows PowerShell 5.1+ | 一键脚本：批量消音 + 弹幕硬编码 |

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
| **FFprobe** | 随 FFmpeg 附带 | 获取音视频元信息；烧录 B站 xml 弹幕时还要用它读分辨率 |
| **Python** | ≥ 3.8 | 脚本运行环境 |
| **PyTorch** | CPU 版即可 (~500MB) | 自动通过 pip 安装；有 NVIDIA GPU 可装 CUDA 版加速 |
| **PowerShell** | ≥ 5.1 | 跑 `一键拆弹_弹幕版.ps1` 才需要；只用 `beep_filter.py` 可以不装 |

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

## 🎬 弹幕硬编码流水线（一键拆弹_弹幕版.ps1）

`beep_filter.py` 只负责消音。如果还想把录播时抓到的弹幕一起烧进画面，用 `一键拆弹_弹幕版.ps1`：
它在原有的「音频消音」之后再加一步「弹幕硬编码」，一条命令跑完整个目录。

### 两个 PowerShell 脚本的分工

| 脚本 | 作用 |
|------|------|
| `一键拆弹.ps1` | 最早的一行版本：把目录里所有 flv 丢给 `beep_filter.py` 消音，产物是 `_消音版.flv` |
| `一键拆弹_弹幕版.ps1` | 在消音之后再烧弹幕，并处理平台前缀、成品封装、异常兜底等（推荐入口） |

### 快速开始

```powershell
# 先预览将要执行的 python / ffmpeg 命令（不改动任何文件）
.\一键拆弹_弹幕版.ps1 -DryRun

# 正式处理脚本所在目录的全部 flv
.\一键拆弹_弹幕版.ps1
```

每一步做的事：

```
输入 <原名>.flv
  │
  ├─ Step 1  调 beep_filter.py 消音               → <原名>_消音版.flv（中间产物）
  │
  └─ Step 2  把同名弹幕硬编码进消音版视频
              · 同名 .ass（抖音 DanmakuRender 录的直播弹幕）→ 直接烧
              · 同名 .xml（B站主站格式弹幕，录播姬导出）    → 先转 ASS 再烧
                                                           → <平台前缀><原名>_消音版_弹幕版.mp4（成品）
```

> 想看更细的执行细节，直接读脚本头部的注释式帮助：`Get-Help .\一键拆弹_弹幕版.ps1 -Full`

### 成品命名与产物

| 规则 | 说明 |
|------|------|
| 平台前缀 | 按弹幕来源加在文件名最前面：抖音录播 → `抖音-`，B站录播 → `B站-` |
| 封装格式 | 默认 MP4（源本就是 h264+aac，封装 mp4 没有额外损失，平台上传兼容性最好）。`-Container` 可改 mov / mkv |
| 中间产物 | **默认烧录成功后就删掉 `_消音版.flv`**，只留带弹幕的成品；想要留着仅消音的视频就加 `-KeepMuted` |
| 重复运行 | 成品已存在就整体跳过（`-Force` 强制重做）；即使跳过也会照常做画布与异常检查 |

例：`录制-1939971443-20261009-134438-193-首次开播，请多关照！.flv` + 同名 `.xml`
→ `B站-录制-1939971443-20261009-134438-193-首次开播，请多关照！_消音版_弹幕版.mp4`

### 主要参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-Directory` | 脚本所在目录 | 待处理目录 |
| `-ModelSize` | `large` | 传给 `beep_filter.py` 的 Whisper 模型（DryRun 预览时默认降到 `tiny`，方便快速调试） |
| `-Container` | `mp4` | 成品封装：`mp4` / `mov` / `mkv` |
| `-VideoEncoder` | `auto` | 优先 NVENC，不可用自动回退 libx264；也可强制 `nvenc` / `x264` |
| `-Quality` | `23` | 编码质量，NVENC 用 `-cq`、x264 用 `-crf`，数值越小画质越好 |
| `-KeepMuted` | 关 | 保留仅消音的 `_消音版` 文件（同样按平台加前缀） |
| `-SkipMute` | 关 | 跳过消音，只给已存在的 `_消音版` 补烧弹幕（配合 `-KeepMuted` 迭代弹幕版面很快） |
| `-SkipDanmaku` | 关 | 只做消音、不烧弹幕（接近原来的 `一键拆弹.ps1`，另外会按平台给成品加前缀） |
| `-Platform` | `auto` | 强制来源：`auto` / `douyin` / `bilibili` / `none` |
| `-StyleFrom` | 自动 | 指定用哪份抖音 ASS 取字体样式；默认自动挑与本视频同朝向的那份 |
| `-FontSize` / `-Lanes` / `-ScrollDuration` | 自动 | 覆盖弹幕字号 / 车道数 / 滚动时长 |
| `-OutputSize` | 自动 | 强制成品画布，例如 `1080x1920` |
| `-ExpectedRatio` | `9:16` | 期望宽高比，明显偏离就在最后提示；写 `none` 关闭这项检查 |
| `-KeepAss` | 关 | 保留 B站 xml 转换出来的 ASS，便于检查或手工微调 |
| `-Force` / `-DryRun` | 关 | 强制重做 / 只预览命令，不改动任何文件 |

### 异常兜底提示

B站连麦时录播姬一般会另起一个新文件，所以单个文件内比例是恒定的，但整个文件可能不是 9:16（双人画面可能是横屏甚至方形）。
这类素材照常处理：弹幕字号按**画面面积开方**缩放、车道按字号比例推导，版面自适应且不拉伸。

全部视频处理完之后，命令行**最底部**会汇总提示本场有没有异常，例如：

```
⚠ 本场直播有异常情况，请留意：
   · [宽高比异常（横屏）] 连麦场.flv
     源画面 1280x720，宽高比 1.778（期望 9:16）——多半是连麦/双人画面；弹幕字号与车道已按面积比适配
```

没有异常时会明确写「本场直播未发现异常情况」。汇总的异常包括：宽高比异常、同一文件内换过画面比例、读不到画面尺寸、处理失败。
纯画布类异常只是提醒（退出码仍为 0），处理失败才以退出码 1 结束。

### 关于 B站 XML 弹幕

**ffmpeg 不能直接读 B站 XML 弹幕**：它的字幕解码器只有 `ass / ssa / srt / subrip / webvtt`，能把文字烧进画面的也只有 `ass` 和 `subtitles` 这两个滤镜（都基于 libass）。
所以 xml 必须先转成 ASS —— 这一步由 `bili_danmaku_to_ass.py` 完成，它不是可选项，而是唯一的通路。

XML 和 ASS 是不同层次的东西，互补而非替代：

| | B站 XML | ASS |
|---|---|---|
| 角色 | **数据/交换格式** | **呈现/渲染格式** |
| 内容 | 时间、模式（滚动/顶部/底部）、字号档位、颜色、文本 | 字体、精确字号、透明度、描边、阴影、对齐，以及 `\move` / `\pos` 等运动指令 |
| 强项 | 平台通用、紧凑、适合当弹幕原始存档 | 渲染确定，表现力完整 |

XML 本身不含字体信息，所以样式取自抖音 ASS（DanmakuRender 输出），按目标画面**面积开方**等比缩放：

| 取自抖音 ASS | 换算到 B站 1080×1920 |
|------|------|
| Microsoft YaHei、加粗 | 同 |
| 字号 42（画布 720×1280） | 63px |
| 主色 `&H33FFFFFF`（白，20% 透明）、描边 `&H33000000` 宽 1.0 | 同色同透明度，描边 1.5 |
| 车道 y=62 起、步长 48、10 条、滚动 16 秒 | y=93 起、步长 72、10 条、滚动 16 秒 |

缩放用的是画面面积开方而不是高度，所以横竖屏互换、720p/1080p 互换都不会算错：宽高比相同时它恰好等价于按高度缩放（竖屏 720p → 竖屏 1080p 就是 42 → 63）。

其它行为：

- 支持模式 1（右→左滚动）、6（左→右滚动）、4（底部固定）、5（顶部固定）；7/8/9（高级/代码/BAS 弹幕）跳过并计数
- 同一条车道要满足「后一条已完全进入画面、且不会被前一条追上」才允许再放；车道不够时**按最小重叠堆叠放置，不丢弃任何弹幕**（想少堆叠可用 `-Lanes` 加宽车道或 `-ScrollDuration` 缩短在屏时间）
- 弹幕里的 `[哇]` 这类表情占位符没有对应的图片表，按原文本显示
- 即使遇到同一文件内换比例（异常情况），烧录前也会先 scale+pad 锁定画布：正常视频是恒等变换（实测 PSNR=inf，无损且耗时无差异），异常片段等比缩放加黑边，不拉伸

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

### Q: 弹幕太密、互相压在一起怎么办？

**A:** 默认沿用抖音样式的 10 条车道，车道不够时按最小重叠堆叠、**不丢弃任何弹幕**。想减少压叠：

```powershell
.\一键拆弹_弹幕版.ps1 -ScrollDuration 12   # 缩短在屏时间（默认 16 秒）
.\一键拆弹_弹幕版.ps1 -Lanes 16            # 加宽车道，代价是弹幕占用更多画面高度
```

### Q: 处理完之后 `_消音版.flv` 怎么不见了？

**A:** 这是默认行为——烧录成功后只保留带弹幕的成品，避免磁盘上留两份。想保留仅消音的视频加 `-KeepMuted`；
如果之后可能还要调弹幕版面重烧，第一次就带上它，否则得重新跑一遍 Whisper（长视频很费时间）。

### Q: 连麦那一场画幅跟平时不一样，会影响弹幕吗？

**A:** 不会。字号按画面面积开方缩放、车道按字号比例推导，横屏或方形素材都能自适应，不拉伸；
全部处理完后还会在命令行最底部提示本场出现了异常宽高比（`-ExpectedRatio none` 可关闭这项检查）。

---

## 📁 项目结构

```
video-beep-filter/
├── beep_filter.py            # 核心：音频消音（Whisper 识别 + ffmpeg 哔声替换）
├── bili_danmaku_to_ass.py    # B站主站格式 XML 弹幕 → ASS（硬编码前必须先转换）
├── 一键拆弹.ps1              # 批量消音（最早的一行版本）
├── 一键拆弹_弹幕版.ps1       # 批量消音 + 弹幕硬编码（推荐入口）
├── README.md                 # 本文件
├── LICENSE                   # 许可证（MIT）
└── .gitignore                # Git 忽略规则（录播素材、成品、中间文件都不入库）
```

---

## 📜 许可证

本项目基于 MIT 许可证开源。详见 [LICENSE](LICENSE) 文件。

---
*Vibe Coding Alert: 99.9% of the code in this repository was generated by Reasonix and DeepSeek-Harness. Thanks to DeepSeek.*

*Made with ❤️ for the live streaming archiving community.*
