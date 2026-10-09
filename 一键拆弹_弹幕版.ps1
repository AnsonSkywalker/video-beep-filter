#Requires -Version 5.1
<#
.SYNOPSIS
    一键拆弹（弹幕版）：先对 FLV 音频消音，再把同名 ASS 直播弹幕硬编码进视频。

.DESCRIPTION
    在原有「对视频的音频流进行消音」流程之后，新增一步弹幕烧录：

      Step 1  对目录下每个 *.flv 调用 beep_filter.py 消音
              → 生成 <原名>_消音版.flv（中间产物）
      Step 2  若该 flv 存在同名弹幕文件，则用 ffmpeg(libass) 把弹幕硬编码进
              Step 1 的消音版视频 → 生成 <平台前缀><原名>_消音版_弹幕版.mp4（成品）
                * .ass（抖音 DanmakuRender 录制的直播弹幕）→ 直接烧录
                * .xml（B站主站格式弹幕，如录播姬导出）→ 先用 bili_danmaku_to_ass.py
                  转成 ASS 再烧录。xml 本身不含字体信息，字体样式自动取本目录下
                  抖音 ASS 的样式（字体/字号/颜色/透明度/描边，以及车道间距与滚动
                  时长，按画面面积开方等比缩放），使两个平台的成品观感保持统一

    成品与命名规则：
      * 硬编码成品默认导出为 MP4（源本就是 h264+aac，封装 mp4 无额外损失，
        且 mp4 对抖音/B站/微信等平台的上传兼容性最好）。可用 -Container 改成 mov / mkv。
      * 默认只保留 _消音版_弹幕版 成品，烧录成功后自动删掉 _消音版 中间产物；
        需要留下仅消音的视频时加 -KeepMuted。
      * 按弹幕来源给成品文件名加前缀：抖音(ass 弹幕) → 抖音-，B站(xml 弹幕) → B站-。
        前缀对「带弹幕」和「仅消音」两种成品都生效。

    要点：
      * 不修改任何原始 flv / ass / xml 文件，也不修改已有的「一键拆弹.ps1」。
      * 烧录必须重新编码视频流，音频流直接复制（-c:a copy），无二次损失。
      * 默认自动优先使用 NVIDIA NVENC 硬件编码，不可用时回退 libx264。
      * 若某 flv 没有同名弹幕文件，则跳过 Step 2，其成品就是 _消音版.flv。
      * 出于过审考虑，Step 2 绝不会退回去烧录「未消音」的原片：
        找不到消音版输出时只报错跳过。
      * 兼容「异常宽高比」的录播：B站连麦时录播机通常会另起一个新文件，所以单个文件内
        比例是恒定的，但该文件可能不是 9:16 竖屏（双人画面可能是横屏/方形）。这类文件
        照常处理：字号按画面面积开方缩放、车道按字号比例推导，版面自适应，不拉伸。
      * 全部视频处理完之后，命令行最底部会汇总提示本场是否出现异常（宽高比偏离期望、
        同一文件内比例不一致、处理失败等），一眼就能看出这场的素材有没有问题。
        期望比例默认 9:16，可用 -ExpectedRatio 调整，写 none 关闭该项检查。
      * 兜底：烧录前一律先 scale+pad 把每帧归一到固定画布，即使真遇到「同一文件内换
        比例」（属异常，正常分段录制不会出现）也不会失败。正常视频这一步是恒等变换
        （实测 PSNR=inf 完全无损、耗时无差异）；比例不同的片段等比缩放加黑边。
        不做这一步的话，中途换比例会让 ffmpeg 直接崩溃、产出损坏文件。
      * DryRun 只预览、不跑 Whisper；未显式指定 -ModelSize 时预览默认用 tiny 以加快
        调试，正式运行仍默认 large。

    B站 xml 弹幕转换说明（bili_danmaku_to_ass.py）：
      * <d p="时间,模式,字号,颜色,...">文本</d>；支持模式 1(右→左)、6(左→右)、
        4(底部固定)、5(顶部固定)；模式 7/8/9(高级/代码/BAS 弹幕) 跳过并计数。
      * 同一条车道要等「后一条已完全进入画面、且不会被前一条追上」才允许再放，
        避免文字互相压叠；车道不够时按最小重叠「堆叠」放置，**不丢弃任何弹幕**。
        想少堆叠可以用 -Lanes 加宽车道、或 -ScrollDuration 缩短在屏时间。
      * B站弹幕里的 [哇] 这类表情占位符无法还原成图片，按原文本显示。
      * 字号按「画面面积开方」缩放（与分辨率、横竖屏无关）：同一宽高比时等价于按
        高度缩放，竖屏抖音 720p → 竖屏 B站 1080p 就是 42→63 像素；竖屏参考配横屏
        视频、或抖音改用 1080p 开播也都算得对。需要钉死字号时用 -FontSize。

.PARAMETER Directory
    待处理目录，默认脚本所在目录。

.PARAMETER ModelSize
    传给 beep_filter.py 的 Whisper 模型大小（tiny/base/small/medium/large），默认 large。

.PARAMETER VideoEncoder
    弹幕烧录的视频编码器：auto（默认，优先 nvenc）/ nvenc / x264。

.PARAMETER Quality
    编码质量，nvenc 为 -cq、x264 为 -crf，默认 23（数值越小画质越好）。

.PARAMETER Container
    硬编码成品的封装格式：mp4（默认）/ mov / mkv。

.PARAMETER Platform
    录播来源，决定成品文件名前缀：auto（默认，自动判断）/ douyin / bilibili / none。
    自动判断优先看弹幕文件内容里的平台特征，判断不出来再按扩展名约定
    （ass → 抖音，xml → B站）。判断错了可以用本参数强制指定。

.PARAMETER PythonPath
    python 可执行文件，默认 python。

.PARAMETER FFmpegPath
    ffmpeg 可执行文件，默认从 PATH 查找。

.PARAMETER FFprobePath
    ffprobe 可执行文件，默认取 ffmpeg 同目录下的 ffprobe.exe，再退回 PATH。
    烧录 B站 xml 弹幕时用它读取视频分辨率，作为 ASS 的 PlayRes。

.PARAMETER StyleFrom
    字体样式来源 ASS（一般不用指定）。烧录 B站 xml 时用于提取字体样式与版面，
    默认自动在本目录里找一份抖音(DanmakuRender)的 ASS 来用；找不到则用脚本内置的
    抖音样式（即从本项目抖音 ASS 中提取的那套）。

.PARAMETER OutputSize
    强制成品的画布尺寸，格式「宽x高」，例如 1080x1920。
    默认不用给：脚本会采样视频中途的画面尺寸投票取多数（这样即使录播一开头就是连麦的
    横屏段、后面才回到正常竖屏，也能选对画布）。
    什么时候要指定：确知想要某个固定输出尺寸时。
    无论是否指定，烧录前都会把每帧归一到该尺寸——正常视频是恒等变换（实测无损），
    中途换过比例的片段会等比缩放加黑边，不会被拉伸。

.PARAMETER ExpectedRatio
    期望的画面宽高比，用于「异常兜底提示」。默认 9:16（=0.5625，手机竖屏直播的常规比例）。
    处理完全部视频后，若有文件的宽高比明显偏离（例如连麦时录播机另起的新文件是横屏
    或方形），会在命令行最底部汇总提示本场有异常。
    可写成 9:16 / 0.5625；写 none 可关闭这项检查。

.PARAMETER Lanes
    覆盖车道数。默认 10 条，且不随来源 ASS 变化（抖音每场录制用几条是弹幕密度决定的，
    不是稳定样式：本项目两份抖音成品就分别是 10 条和 9 条）。弹幕很密时可以调大以减少
    堆叠，代价是弹幕占用的画面高度变大。

.PARAMETER FontSize
    直接指定弹幕字号（像素，相对目标视频画布），给了就不再由来源样式推算。
    默认按「画面面积开方」缩放：宽高比相同时它等价于按高度缩放（竖屏 720p 抖音 →
    竖屏 1080p B站 即 42→63）；宽高比不同时也能保持弹幕相对画面的大小不变——
    竖屏参考配横屏视频不会再被压成 20 多像素，抖音换成 1080p 开播也不会算错。

.PARAMETER ScrollDuration
    覆盖滚动弹幕在屏时长（秒）。默认沿用来源 ASS（抖音样式为 16 秒）。调小可显著
    减少堆叠（例如 12 秒）。

.PARAMETER KeepAss
    保留 B站 xml 转换出来的 ASS 文件（与成品同名、扩展名为 .ass），便于检查或手工微调。
    默认不保留（只放在临时目录里）。

.PARAMETER SkipMute
    跳过消音，仅对已存在的 _消音版 文件烧录弹幕。

.PARAMETER SkipDanmaku
    跳过弹幕烧录，只出消音版成品（成品名仍按平台加前缀）。

.PARAMETER KeepMuted
    额外保留仅消音的视频文件（默认烧录成功后会删掉 _消音版 中间产物）。
    保留的文件同样按平台加前缀。

.PARAMETER Force
    强制重做：覆盖已存在的成品，并重跑消音步骤。

.PARAMETER DryRun
    只打印将执行的命令，不实际执行（不产生/删除/改名任何文件）。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1
    处理脚本所在目录的全部 flv：消音 + 烧录同名弹幕，只留 MP4 成品。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -Directory "D:\录播" -ModelSize large
    指定目录与模型大小。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -KeepMuted
    烧录弹幕的同时，把仅消音的 _消音版 文件也留下。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -SkipMute
    已经消音过的视频，只补烧弹幕（需要 _消音版 文件还在）。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -DryRun
    预览将要执行的 python / ffmpeg 命令。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -Platform douyin -Container mkv
    没有弹幕文件也能强制加「抖音-」前缀，并改用 mkv 封装。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -Directory "D:\B站录播"
    处理 B站录播：把同名 xml 弹幕转成 ASS（字体样式取自本目录的抖音 ASS）后
    硬编码进消音版视频，成品形如 　B站-录制-xxx_消音版_弹幕版.mp4。

.EXAMPLE
    .\一键拆弹_弹幕版.ps1 -Directory "D:\B站录播" -Lanes 16 -ScrollDuration 12 -KeepAss
    B站弹幕很密时加宽到 16 条车道、缩短在屏时间以减少文字压叠，并保留转换出的 ASS。
#>
[CmdletBinding()]
param(
    [string]$Directory,
    [string]$ModelSize = 'large',
    [ValidateSet('auto', 'nvenc', 'x264')]
    [string]$VideoEncoder = 'auto',
    [int]$Quality = 23,
    [ValidateSet('mp4', 'mov', 'mkv')]
    [string]$Container = 'mp4',
    [ValidateSet('auto', 'douyin', 'bilibili', 'none')]
    [string]$Platform = 'auto',
    [string]$PythonPath = 'python',
    [string]$FFmpegPath,
    [string]$FFprobePath,
    [string]$StyleFrom,
    [string]$OutputSize,
    [string]$ExpectedRatio = '9:16',
    [int]$Lanes = 0,
    [double]$FontSize = 0,
    [double]$ScrollDuration = 0,
    [switch]$KeepAss,
    [switch]$SkipMute,
    [switch]$SkipDanmaku,
    [switch]$KeepMuted,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# 控制台按 UTF-8 输出，保证中文文件名/日志不乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = 'utf-8'

# DryRun 只预览、不跑 Whisper，但我们习惯先 DryRun 再照着跑一遍；
# 未显式给 -ModelSize 时，DryRun 默认用最快的小模型，省得每次手打 tiny。
# 正式运行（不加 -DryRun）仍默认 large，出片不受影响。
$modelExplicit = $PSBoundParameters.ContainsKey('ModelSize')
$modelAutoFast = $false
if ($DryRun -and -not $modelExplicit) {
    $ModelSize = 'tiny'
    $modelAutoFast = $true
}

# 期望宽高比（异常兜底提示用）：默认 9:16 = 0.5625
$ratioCheckOn = $true
$expectedRatioValue = 0.5625
if ($ExpectedRatio -match '^\s*(?i:none|off|no)\s*$') {
    $ratioCheckOn = $false
}
elseif ($ExpectedRatio -match '^\s*(\d+(?:\.\d+)?)\s*[:/]\s*(\d+(?:\.\d+)?)\s*$') {
    $expectedRatioValue = [double]$Matches[1] / [double]$Matches[2]
}
elseif ($ExpectedRatio -match '^\s*(\d+(?:\.\d+)?)\s*$') {
    $expectedRatioValue = [double]$Matches[1]
}
else {
    throw "-ExpectedRatio 格式应为 9:16、0.5625 或 none，当前值: $ExpectedRatio"
}
# 偏离超过 5% 就算异常（同一比例的不同分辨率不会触发）
$ratioTolerance = 0.05

# ---------- 常量 ----------
$MUTED_TAG = '_消音版'
$DANMAKU_TAG = '_弹幕版'
# 平台前缀表
$PlatformPrefix = @{
    douyin   = '抖音-'
    bilibili = 'B站-'
    none     = ''
}
# 编码器质量参数：nvenc 用 -cq，x264 用 -crf
$EncoderArgs = @{
    nvenc = @('-c:v', 'h264_nvenc', '-preset', 'p5', '-rc', 'vbr', '-b:v', '0', '-pix_fmt', 'yuv420p')
    x264  = @('-c:v', 'libx264', '-preset', 'medium', '-pix_fmt', 'yuv420p')
}
# B站 xml 弹幕 → ASS 的转换脚本
$BiliConverterName = 'bili_danmaku_to_ass.py'

# ---------- 小工具 ----------
function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "── $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) { Write-Host "   [OK] $Text" -ForegroundColor Green }

# 产物提示：DryRun 下不能说「已生成」，那只是预览
function Write-Produced([string]$Path) {
    if ($DryRun) {
        Write-Host "   [DryRun] 将生成 $(Split-Path -Leaf $Path)" -ForegroundColor DarkCyan
    }
    else {
        Write-Ok "已生成 $(Split-Path -Leaf $Path)"
    }
}
function Write-Skip([string]$Text) { Write-Host "   [跳过] $Text" -ForegroundColor DarkGray }
function Write-Warn([string]$Text) { Write-Host "   [警告] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host "   [失败] $Text" -ForegroundColor Red }

function Format-Argv {
    param([string]$Exe, [string[]]$Arguments)
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '[\s&()]') { '"' + $_ + '"' } else { $_ }
    }
    return ($Exe + ' ' + ($quoted -join ' '))
}

# 执行外部命令；返回退出码。DryRun 时只打印不执行。
function Invoke-External {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )
    if ($DryRun) {
        Write-Host ('   [DryRun] ' + (Format-Argv -Exe $Exe -Arguments $Arguments)) -ForegroundColor DarkCyan
        return 0
    }
    Push-Location -LiteralPath $WorkingDirectory
    try {
        # 子进程 stdout 必须经 Out-Host 直接打到控制台。
        # 若写成 `& $Exe @Arguments`，子进程的 stdout 会被当作本函数的“返回值”，
        # 和退出码一起返回（$code 变成数组），退出码判断随即失效。
        & $Exe @Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

# 真实探测 NVENC 是否可用（驱动缺失时 ffmpeg 会报错退出）
function Test-NvencAvailable {
    param([string]$FFmpeg)
    # 分辨率不能太小：NVENC 对帧尺寸有下限，128x128 会因
    # "Frame Dimension less than the minimum supported value" 被误判为不可用
    $probe = @(
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=0.1',
        '-c:v', 'h264_nvenc', '-f', 'null', '-'
    )
    & $FFmpeg @probe 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# 判断录播来源（决定成品文件名前缀）
function Resolve-Platform {
    param(
        [string]$AssPath,
        [string]$XmlPath,
        [string]$Override   # auto / douyin / bilibili / none
    )
    if ($Override -ne 'auto') {
        return @{ Key = $Override; Reason = '-Platform 强制指定' }
    }

    if (Test-Path -LiteralPath $AssPath) {
        # 只读文件头部 8KB，足以看到 ass 注释里的平台特征
        $head = ''
        try {
            $fs = [System.IO.File]::OpenRead($AssPath)
            try {
                $buf = New-Object byte[] 8192
                $n = $fs.Read($buf, 0, $buf.Length)
                $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            }
            finally { $fs.Dispose() }
        }
        catch { }

        if ($head -match 'douyin|抖音|iesdouyin') {
            return @{ Key = 'douyin'; Reason = 'ass 头部含抖音特征' }
        }
        if ($head -match 'bilibili|b23\.tv|hdslb|B站') {
            return @{ Key = 'bilibili'; Reason = 'ass 头部含B站特征' }
        }
        # 特征看不出来就按扩展名约定：ass 弹幕 → 抖音
        return @{ Key = 'douyin'; Reason = 'ass 弹幕（按约定视为抖音）' }
    }

    if (Test-Path -LiteralPath $XmlPath) {
        return @{ Key = 'bilibili'; Reason = 'xml 弹幕（按约定视为B站）' }
    }

    return @{ Key = 'none'; Reason = '没有弹幕文件，无法判断来源' }
}

# 在「无前缀」和「带前缀」两个候选名里找出已存在的消音版文件
function Find-MutedFile {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# 找一份「抖音(DanmakuRender)生成的 ASS」当字体样式来源。
# 认文件头部特征（DanmakuRender 署名 / live.douyin.com / 抖音），
# 并跳过本流程自己产出的 _弹幕版 文件；找不到就返回 $null（改用脚本内置样式）。
function Find-DouyinStyleAss {
    param(
        [string]$Dir,
        # 目标视频的宽高比。给了就优先挑「朝向一致」的那份参考
        # （目录里同时躺着竖屏和横屏的抖音成品时，避免拿错朝向）。
        [double]$TargetRatio = 0
    )
    $cands = @(
        Get-ChildItem -LiteralPath $Dir -Filter '*.ass' |
            Where-Object {
                (-not $_.PSIsContainer) -and
                -not ([System.IO.Path]::GetFileNameWithoutExtension($_.Name)).EndsWith(
                    $DANMAKU_TAG, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object LastWriteTime -Descending
    )

    $found = @()
    foreach ($c in $cands) {
        $head = ''
        try {
            $fs = [System.IO.File]::OpenRead($c.FullName)
            try {
                $buf = New-Object byte[] 4096
                $n = $fs.Read($buf, 0, $buf.Length)
                $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            }
            finally { $fs.Dispose() }
        }
        catch { }
        if ($head -notmatch 'DanmakuRender|live\.douyin\.com|iesdouyin|抖音') { continue }

        # 顺带记下参考画布宽高比，用于按朝向优选
        $ratio = 0.0
        $mx = [regex]::Match($head, 'PlayResX:\s*(\d+)')
        $my = [regex]::Match($head, 'PlayResY:\s*(\d+)')
        if ($mx.Success -and $my.Success) {
            $rx = [double]$mx.Groups[1].Value
            $ry = [double]$my.Groups[1].Value
            if ($rx -gt 0 -and $ry -gt 0) { $ratio = $rx / $ry }
        }
        $found += [pscustomobject]@{ Path = $c.FullName; Ratio = $ratio; Time = $c.LastWriteTime }
    }

    if ($found.Count -eq 0) { return $null }

    if ($TargetRatio -gt 0) {
        $same = $found |
            Where-Object { $_.Ratio -gt 0 -and ([math]::Abs($_.Ratio - $TargetRatio) / $TargetRatio) -le 0.02 } |
            Sort-Object Time -Descending
        if ($same) {
            return [pscustomobject]@{ Path = $same[0].Path; SameOrientation = $true }
        }
    }
    # 没有同朝向的就退回最新的一份（调用方会说明这是「退回取得」）
    return [pscustomobject]@{ Path = ($found | Sort-Object Time -Descending)[0].Path; SameOrientation = $false }
}

# 读视频宽高，作为 ASS 的 PlayRes
function Get-VideoSize {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe) { return $null }
    $out = & $FFprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $first = ($out | Select-Object -First 1).ToString().Trim()
    $parts = $first -split ','
    if ($parts.Count -lt 2) { return $null }
    $w = 0; $h = 0
    if (-not [int]::TryParse($parts[0], [ref]$w)) { return $null }
    if (-not [int]::TryParse($parts[1], [ref]$h)) { return $null }
    if ($w -le 0 -or $h -le 0) { return $null }
    return @{ Width = $w; Height = $h }
}

# 把消音版整理到带平台前缀的成品名（同目录改名，不额外占磁盘）
function Set-MutedName {
    param([string]$From, [string]$To)
    if ($DryRun) { return $To }
    if ($From -eq $To) { return $To }
    if (-not (Test-Path -LiteralPath $From)) { return $To }
    if (Test-Path -LiteralPath $To) {
        # 目标名已存在（多为上次运行的遗留同名文件），删掉无前缀的那份即可
        Remove-Item -LiteralPath $From -Force
        return $To
    }
    Move-Item -LiteralPath $From -Destination $To
    return $To
}

# 采样视频在几个时间点的「真实画面尺寸」。
# 为什么需要：B站连麦等场景会让录播中途换画面比例，同一个文件里前后尺寸可能不一致；
# 而容器的 stream 尺寸只反映第一段（ffprobe 对混合分辨率文件也只报第一段的尺寸）。
# 实现上 seek 到采样点后只解一帧，用 showinfo 滤镜输出（形如 s:1080x1920）。
# 不用解析 "Stream #0:0: Video:" 那类文字，因为 ffmpeg 的日志标签会被本地化。
# 属于 best-effort：采样点之间的短暂切换可能漏掉，但漏掉也不影响正确性
# （烧录时一律会做尺寸归一化，见 Get-OutputCanvas）。
function Get-VideoLayoutSamples {
    param([string]$FFmpeg, [string]$Path, [double]$Duration)
    $sizes = @()
    if (-not $FFmpeg -or $Duration -le 0) { return $sizes }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($frac in @(0.25, 0.5, 0.75, 0.98)) {
        $t = [math]::Round($Duration * $frac, 2)
        if ($t -le 0) { continue }
        # 用 .NET 直接起进程抓 stderr，不走 PowerShell 的错误流：
        # showinfo 的结果在 stderr 上，而 Windows PowerShell 5.1 里把原生程序的 stderr
        # 重定向进管道（2>&1）会生成 NativeCommandError，配合 $ErrorActionPreference='Stop'
        # 会直接把整个脚本中断（在 PS7 下却没事，所以更容易漏掉）。
        $txt = ''
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $FFmpeg
            $psi.Arguments = '-hide_banner -v info -ss ' + $t.ToString($inv) +
                ' -i "' + $Path + '" -frames:v 1 -vf showinfo -f null -'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $txt = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $proc.Dispose()
        }
        catch { continue }
        $m = [regex]::Match($txt, 's:(\d+)x(\d+)')
        if ($m.Success) { $sizes += "$($m.Groups[1].Value)x$($m.Groups[2].Value)" }
    }
    return $sizes
}

function Get-VideoDuration {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe) { return 0.0 }
    $out = & $FFprobe -v error -show_entries format=duration -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0.0 }
    $d = 0.0
    if ([double]::TryParse((($out | Select-Object -First 1).ToString().Trim()), [ref]$d)) { return $d }
    return 0.0
}

# 决定成品画布尺寸（同时也是 ASS 的 PlayRes）。
# 把「容器声明的尺寸」和「采样到的各时间点尺寸」一起投票，取多数的那一种，
# 这样即使录播一开头就是连麦的横屏段、后面才是正常竖屏，也能选对画布。
# 找不到任何尺寸信息时返回 $null（此时不做归一化，退回旧行为）。
function Get-OutputCanvas {
    param([string]$FFprobe, [string]$FFmpeg, [string]$Path, [string]$Override)

    $forcedW = 0
    $forcedH = 0
    if ($Override) {
        if ($Override -notmatch '^\s*(\d+)\s*[xX×*]\s*(\d+)\s*$') {
            throw "-OutputSize 格式应为 宽x高（例如 1080x1920），当前值: $Override"
        }
        $forcedW = [int]$Matches[1]
        $forcedH = [int]$Matches[2]
    }

    # 即使强制了输出尺寸，也照样探一遍源尺寸：异常提示要用它判断「源是不是连麦画面」。
    # 探不到也没关系（那就只按强制尺寸归一化，这正是 -OutputSize 的一个用途）。
    $declared = Get-VideoSize -FFprobe $FFprobe -Path $Path
    $declaredSize = if ($declared) { "$($declared.Width)x$($declared.Height)" } else { $null }
    $dur = Get-VideoDuration -FFprobe $FFprobe -Path $Path
    $samples = Get-VideoLayoutSamples -FFmpeg $FFmpeg -Path $Path -Duration $dur

    $all = @()
    if ($declaredSize) { $all += $declaredSize }
    $all += $samples

    if ($all.Count -eq 0) {
        # 探不到源尺寸：只有给了 -OutputSize 才能继续（按强制尺寸归一化）
        if ($forcedW -gt 0) {
            return @{ Width = $forcedW; Height = $forcedH; SourceWidth = 0; SourceHeight = 0
                Mixed = $false; Variants = @(); Forced = $true }
        }
        return $null
    }

    $groups = @($all | Group-Object | Sort-Object Count -Descending)
    # 票数相同时优先信容器声明的尺寸（它通常是主导画面）
    $topNames = @($groups | Where-Object { $_.Count -eq $groups[0].Count } | ForEach-Object { $_.Name })
    $winName = if ($declaredSize -and ($topNames -contains $declaredSize)) { $declaredSize } else { $groups[0].Name }

    $parts = $winName -split 'x'
    $variants = @($groups | ForEach-Object { "$($_.Name)×$($_.Count)" })
    return @{
        Width        = if ($forcedW -gt 0) { $forcedW } else { [int]$parts[0] }
        Height       = if ($forcedH -gt 0) { $forcedH } else { [int]$parts[1] }
        SourceWidth  = [int]$parts[0]
        SourceHeight = [int]$parts[1]
        Mixed        = ($groups.Count -gt 1)
        Variants     = $variants
        Forced       = ($forcedW -gt 0)
    }
}

# ---------- 环境准备 ----------
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Directory) { $Directory = $scriptDir }
if (-not (Test-Path -LiteralPath $Directory)) { throw "目录不存在: $Directory" }
$Directory = (Resolve-Path -LiteralPath $Directory).Path

$beepScript = Join-Path $scriptDir 'beep_filter.py'
if (-not (Test-Path -LiteralPath $beepScript)) { throw "找不到 beep_filter.py: $beepScript" }

Write-Host ''
Write-Host '===== 一键拆弹（弹幕版）=====' -ForegroundColor Magenta
Write-Host "  目录     : $Directory"
Write-Host "  模型     : $ModelSize$(if ($modelAutoFast) { '（DryRun 预览默认 tiny；正式运行默认 large，可用 -ModelSize 指定）' })"
Write-Host "  消音     : $(if ($SkipMute) { '跳过' } else { '执行' })"
Write-Host "  弹幕烧录 : $(if ($SkipDanmaku) { '跳过' } else { '执行' })"
Write-Host "  仅消音文件: $(if ($KeepMuted) { '保留' } else { '不保留（默认）' })"
Write-Host "  成品封装 : $Container"
Write-Host "  来源判断 : $Platform"
if ($ratioCheckOn) {
    Write-Host "  宽高比校验: 期望 $ExpectedRatio（有异常会在最后汇总提示；-ExpectedRatio none 可关闭）"
}
if ($DryRun) { Write-Host '  模式     : DryRun（仅预览命令，不改动任何文件）' -ForegroundColor Yellow }

# ffmpeg 仅在需要烧录弹幕时解析
$needDanmaku = -not $SkipDanmaku
if ($needDanmaku) {
    if (-not $FFmpegPath) {
        $ffCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if (-not $ffCmd) { throw 'PATH 中找不到 ffmpeg，请用 -FFmpegPath 指定，或加 -SkipDanmaku 只做消音。' }
        $FFmpegPath = $ffCmd.Source
    }
    elseif (-not (Test-Path -LiteralPath $FFmpegPath)) {
        throw "找不到 ffmpeg: $FFmpegPath"
    }

    if ($VideoEncoder -eq 'auto') {
        if (Test-NvencAvailable -FFmpeg $FFmpegPath) {
            $VideoEncoder = 'nvenc'
        }
        else {
            $VideoEncoder = 'x264'
        }
    }
    # ffprobe：烧录 B站 xml 弹幕时要用它读视频分辨率作为 ASS 的 PlayRes
    if (-not $FFprobePath) {
        $pbCand = Join-Path (Split-Path -Parent $FFmpegPath) 'ffprobe.exe'
        if (Test-Path -LiteralPath $pbCand) {
            $FFprobePath = $pbCand
        }
        else {
            $pbCmd = Get-Command ffprobe -ErrorAction SilentlyContinue
            if ($pbCmd) { $FFprobePath = $pbCmd.Source }
        }
    }
    if ($StyleFrom -and -not (Test-Path -LiteralPath $StyleFrom)) {
        throw "找不到 -StyleFrom 指定的 ASS: $StyleFrom"
    }

    Write-Host "  编码器   : $VideoEncoder$(if ($Quality) { " (quality=$Quality)" })"
    Write-Host "  ffmpeg   : $FFmpegPath"
    if (-not $FFprobePath) {
        Write-Warn '找不到 ffprobe：烧录 B站 xml 弹幕时无法读取视频分辨率，将退回 1080x1920'
    }
    if ($StyleFrom) {
        Write-Host "  字体样式 : 指定 $(Split-Path -Leaf $StyleFrom)"
    }
    if ($Lanes -gt 0) { Write-Host "  车道数   : $Lanes（覆盖默认）" }
    if ($FontSize -gt 0) { Write-Host "  字号     : $FontSize px（覆盖默认）" }
    if ($ScrollDuration -gt 0) { Write-Host "  滚动时长 : $ScrollDuration 秒（覆盖默认）" }
}

$vArgs = @()
$containerArgs = @()
if ($needDanmaku) {
    $vArgs = $EncoderArgs[$VideoEncoder] + @("-$(if ($VideoEncoder -eq 'nvenc') { 'cq' } else { 'crf' })", "$Quality")
    # mp4/mov 加 faststart，把索引移到文件头部，便于上传后边下边播；mkv 不支持此选项
    if ($Container -eq 'mp4' -or $Container -eq 'mov') {
        $containerArgs = @('-movflags', '+faststart')
    }
}

# ---------- 收集待处理文件 ----------
# 只排除本流程/beep_filter 产出的文件，避免二次运行时把成品又当成新素材。
# 按「主文件名后缀」判断而不是完整文件名的后缀，这样与封装格式无关：
#   X_消音版.flv / X_消音版_弹幕版.mp4 / X_消音版_弹幕版.flv / X_消音版_手动修改.flv
# 都能被排除；而名字中间恰好含这些字样的原始素材（如 xxx_消音版原片.flv）仍会正常处理。
$producedStemSuffixes = @($MUTED_TAG, $DANMAKU_TAG, '_手动修改')
$flvs = @(
    Get-ChildItem -LiteralPath $Directory -Filter '*.flv' |
        Where-Object {
            if ($_.PSIsContainer) {
                $false
            }
            else {
                $stemName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                $isProduced = $false
                foreach ($suffix in $producedStemSuffixes) {
                    if ($stemName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $isProduced = $true
                        break
                    }
                }
                -not $isProduced
            }
        } |
        Sort-Object Name
)

if ($flvs.Count -eq 0) {
    Write-Warn "目录中没有可处理的 .flv 文件: $Directory"
    exit 0
}
Write-Host "  待处理   : $($flvs.Count) 个 flv" -ForegroundColor Gray

# ---------- 主流程 ----------
$results = New-Object System.Collections.ArrayList
# 异常清单：跑完全部视频后在命令行最底部汇总提示（兜底提醒）
$anomalies = New-Object System.Collections.ArrayList
$failed = 0
# 抖音样式 ASS 按「视频宽高比」缓存：同一目录里可能既有竖屏也有横屏的录播，
# 不能只认第一份。
$styleCache = @{}
$biliConverter = Join-Path $scriptDir $BiliConverterName
# B站 xml 转换结果是否已提示过「缺少转换脚本」
$convMissingWarned = $false

foreach ($flv in $flvs) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($flv.Name)
    # 注意必须用 ${stem} 花括号：$stem_消音版 会被解析成变量名 stem_消音版

    # beep_filter.py 固定输出这个名字（无前缀），作为中间产物
    $mutedPlain = Join-Path $Directory "${stem}${MUTED_TAG}.flv"
    # 带上平台前缀的消音版成品名
    $assPath = Join-Path $Directory "${stem}.ass"
    $xmlPath = Join-Path $Directory "${stem}.xml"

    $plat = Resolve-Platform -AssPath $assPath -XmlPath $xmlPath -Override $Platform
    $prefix = $PlatformPrefix[$plat.Key]

    $mutedFinal = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}.flv"
    $danmakuPath = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}${DANMAKU_TAG}.${Container}"

    $hasAss = Test-Path -LiteralPath $assPath
    $hasXml = Test-Path -LiteralPath $xmlPath
    # ass（抖音）可直接烧；xml（B站）要先转成 ASS，两者都能出弹幕成品。
    # 万一同名 ass 与 xml 同时存在，以 ass 为准（不再重复烧一遍 xml）。
    $willBurn = ($hasAss -or $hasXml) -and -not $SkipDanmaku

    Write-Step "[$($flv.Name)]"
    Write-Host "   来源判断 : $($plat.Key) → 前缀 '$prefix'（$($plat.Reason)）" -ForegroundColor DarkGray

    $finalPath = if ($willBurn) { $danmakuPath } else { $mutedFinal }

    # ---- 画布探测 + 异常检查 ----
    # 特意放在「成品已存在就跳过」之前：已经出过片的素材同样要参与异常检查，
    # 否则重跑一遍会在什么都没查的情况下报「未发现异常」，那就成了假安慰。
    # B站连麦时录播机一般会另起一个新文件，所以同一文件内比例是恒定的；这里投票取
    # 多数是为了兜住「万一同一文件内换了比例」——那种情况直接上 ass 滤镜会让 ffmpeg
    # 崩溃（实测 0xC0000005）并留下损坏的 mp4。
    # scale+pad 归一化的代价：正常视频是恒等变换（实测 PSNR=inf、耗时无差异）。
    # 直接量原始 flv：beep_filter 的消音步骤对视频流一律 -c:v copy，
    # 消音版的分辨率/比例必然与原始文件一致，不必等中间产物生成。
    $probeTarget = $flv.FullName
    $canvas = Get-OutputCanvas -FFprobe $FFprobePath -FFmpeg $FFmpegPath -Path $probeTarget -Override $OutputSize
    $vfNorm = ''
    if ($canvas) {
        $cw = $canvas.Width
        $ch = $canvas.Height
        $vfNorm = "scale=${cw}:${ch}:force_original_aspect_ratio=decrease,pad=${cw}:${ch}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1"
        if ($canvas.Mixed) {
            Write-Warn "这段录播中途换过画面比例（检测到 $($canvas.Variants -join ' / ')）"
            Write-Host "             已统一为 ${cw}x${ch} 输出：比例不同的片段会等比缩放加黑边，不拉伸" -ForegroundColor DarkGray
            [void]$anomalies.Add([pscustomobject]@{
                    Kind   = '中途换过画面比例'
                    File   = $flv.Name
                    Detail = "同一文件里检测到 $($canvas.Variants -join ' / ')；已统一为 ${cw}x${ch}（等比缩放加黑边）"
                })
        }
        elseif ($canvas.Forced) {
            Write-Host "   画布     : ${cw}x${ch}（-OutputSize 指定）" -ForegroundColor DarkGray
        }
        else {
            Write-Host "   画布     : ${cw}x${ch}（尺寸一致，归一化为恒等变换）" -ForegroundColor DarkGray
        }

        # 宽高比异常（连麦时录播机另起的新文件，可能是横屏/方形）
        # 判断用「源画面」尺寸：即使 -OutputSize 强制了输出尺寸，也要能报出来源异常
        if ($ratioCheckOn) {
            $sw = if ($canvas.SourceWidth -gt 0) { $canvas.SourceWidth } else { $cw }
            $sh = if ($canvas.SourceHeight -gt 0) { $canvas.SourceHeight } else { $ch }
            $thisRatio = $sw / [double]$sh
            if ([math]::Abs($thisRatio - $expectedRatioValue) / $expectedRatioValue -gt $ratioTolerance) {
                $kind = if ($thisRatio -gt 1.0) { '宽高比异常（横屏）' } else { '宽高比异常' }
                Write-Host "   [注意]   源画面 ${sw}x${sh}，宽高比 $([math]::Round($thisRatio, 3))，不是常规的 $ExpectedRatio" -ForegroundColor Yellow
                $detail = "源画面 ${sw}x${sh}，宽高比 $([math]::Round($thisRatio, 3))（期望 $ExpectedRatio）——多半是连麦/双人画面；弹幕字号与车道已按面积比适配"
                if ($canvas.Forced) { $detail += "；已按 -OutputSize 归一化为 ${cw}x${ch}" }
                [void]$anomalies.Add([pscustomobject]@{
                        Kind   = $kind
                        File   = $flv.Name
                        Detail = $detail
                    })
            }
        }
    }
    else {
        Write-Warn '读不到视频尺寸，跳过尺寸归一化；若这段录播中途换过画面比例，烧录可能失败'
        [void]$anomalies.Add([pscustomobject]@{
                Kind   = '读不到画面尺寸'
                File   = $flv.Name
                Detail = '已跳过尺寸归一化，异常比例下烧录可能失败'
            })
    }

    # 成品已存在则整体跳过，避免重复劳动（注意：上面的异常检查已经做过了）
    if ((Test-Path -LiteralPath $finalPath) -and -not $Force) {
        Write-Skip "已存在成品 $(Split-Path -Leaf $finalPath)，跳过（-Force 可强制重做）"
        [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '已存在(跳过)'; Output = $finalPath; Extras = @() })
        continue
    }

    # ---- Step 1: 消音（中间产物）----
    $mutedPath = $null
    $existingMuted = Find-MutedFile -Paths @($mutedPlain, $mutedFinal)

    if ($SkipMute) {
        if ($existingMuted) {
            Write-Skip "指定 -SkipMute，直接复用 $(Split-Path -Leaf $existingMuted)"
            $mutedPath = $existingMuted
        }
        else {
            Write-Err "指定了 -SkipMute，但找不到消音版: $(Split-Path -Leaf $mutedPlain)"
            $failed++
            [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '缺少消音版'; Output = $mutedFinal; Extras = @() })
            continue
        }
    }
    elseif ($existingMuted -and -not $Force) {
        Write-Skip "已存在 $(Split-Path -Leaf $existingMuted)，跳过消音（-Force 可强制重做）"
        $mutedPath = $existingMuted
    }
    else {
        Write-Host "   Step 1 消音中（Whisper $ModelSize）..." -ForegroundColor Gray
        $pyArgs = @($beepScript, $flv.FullName, '--model-size', $ModelSize)
        $code = Invoke-External -Exe $PythonPath -Arguments $pyArgs -WorkingDirectory $scriptDir

        $muteOk = ($code -eq 0)
        if (-not $DryRun -and -not (Test-Path -LiteralPath $mutedPlain)) { $muteOk = $false }
        if (-not $muteOk) {
            Write-Err "消音失败或未生成输出（退出码 $code）"
            $failed++
            [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '消音失败'; Output = $mutedFinal; Extras = @() })
            continue
        }
        $mutedPath = $mutedPlain
        Write-Produced $mutedPath
    }

    # ---- Step 2: 弹幕硬编码 ----
    $extras = @()
    if ($willBurn) {
        $mutedAvailable = $DryRun -or (Test-Path -LiteralPath $mutedPath)
        if (-not $mutedAvailable) {
            # 过审场景下绝不拿未消音的原片去烧弹幕
            Write-Err "找不到消音版 $(Split-Path -Leaf $mutedPath)，拒绝烧录未消音原片"
            $failed++
            [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '缺少消音版'; Output = $mutedFinal; Extras = @() })
            continue
        }

        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('danmaku_' + [guid]::NewGuid().ToString('N'))
        try {
            # ---- 准备要烧录的 ASS：ass 直接用，xml 先转换 ----
            # 统一放到临时目录、命名为纯 ASCII 的 danmaku.ass：
            # 规避 ffmpeg 滤镜里 Windows 路径转义（盘符冒号、反斜杠、全角括号、&）的坑，
            # 同时让 libass 稳定地按 UTF-8 解析字幕。
            $workAss = Join-Path $workDir 'danmaku.ass'
            $prepOk = $true

            # 画布与异常检查已在循环开头完成（$canvas / $vfNorm）

            if ($hasAss) {
                if (-not $DryRun) {
                    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
                    $assText = [System.IO.File]::ReadAllText($assPath)
                    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                    [System.IO.File]::WriteAllText($workAss, $assText, $utf8NoBom)
                }
            }
            else {
                if (-not (Test-Path -LiteralPath $biliConverter)) {
                    Write-Err "找不到转换脚本 $(Split-Path -Leaf $biliConverter)，无法把 xml 弹幕转成 ASS"
                    if (-not $convMissingWarned) {
                        Write-Warn "请确认 $BiliConverterName 与本脚本放在同一目录：$scriptDir"
                        $convMissingWarned = $true
                    }
                    $failed++
                    [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '缺少转换脚本'; Output = $mutedFinal; Extras = @() })
                    continue
                }

                # ASS 的 PlayRes 必须等于归一化后的画布，这样即使原片中途换比例，
                # 弹幕坐标也不会被 libass 二次拉伸
                $vsize = if ($canvas) {
                    @{ Width = $canvas.Width; Height = $canvas.Height }
                }
                else {
                    @{ Width = 1080; Height = 1920 }
                }

                # B站 xml：字体样式优先用 -StyleFrom，否则在本目录里找抖音 ASS，
                # 都找不到就用转换脚本内置的抖音样式。
                # 找的时候带上本视频的宽高比，目录里有多份抖音成品时优先挑同朝向的；
                # 结果按宽高比缓存，夹着横竖屏混排的录播也能各挑各的。
                $styleForThis = $StyleFrom
                if (-not $styleForThis) {
                    $ratioKey = '{0:N3}' -f ($vsize.Width / [double]$vsize.Height)
                    if (-not $styleCache.ContainsKey($ratioKey)) {
                        $picked = Find-DouyinStyleAss -Dir $Directory -TargetRatio ($vsize.Width / [double]$vsize.Height)
                        $styleCache[$ratioKey] = $picked
                        if ($picked) {
                            $why = if ($picked.SameOrientation) {
                                '与本视频朝向一致'
                            }
                            else {
                                '目录里没有同朝向的参考，退回最新一份（字号会按面积比缩放）'
                            }
                            Write-Host "   字体样式 : 取自 $(Split-Path -Leaf $picked.Path)（$why）" -ForegroundColor DarkGray
                        }
                        else {
                            Write-Warn '本目录没有抖音 ASS，改用内置的抖音样式（字体/字号/颜色与抖音成品一致）'
                        }
                    }
                    if ($styleCache[$ratioKey]) { $styleForThis = $styleCache[$ratioKey].Path }
                }

                if (-not $DryRun) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
                $cvArgs = @(
                    $biliConverter, $xmlPath,
                    '-o', $workAss,
                    '--width', "$($vsize.Width)",
                    '--height', "$($vsize.Height)"
                )
                if ($styleForThis) { $cvArgs += @('--style-from', $styleForThis) }
                if ($Lanes -gt 0) { $cvArgs += @('--lanes', "$Lanes") }
                if ($FontSize -gt 0) { $cvArgs += @('--font-size', "$FontSize") }
                if ($ScrollDuration -gt 0) { $cvArgs += @('--duration', "$ScrollDuration") }

                Write-Host "   转换弹幕 : $(Split-Path -Leaf $xmlPath) → ASS（$($vsize.Width)x$($vsize.Height)）" -ForegroundColor Gray
                $convCode = Invoke-External -Exe $PythonPath -Arguments $cvArgs -WorkingDirectory $scriptDir
                if ($convCode -ne 0 -or (-not $DryRun -and -not (Test-Path -LiteralPath $workAss))) {
                    Write-Err "xml 弹幕转换失败（退出码 $convCode）"
                    $prepOk = $false
                }
            }

            if ($prepOk) {
                Write-Host "   Step 2 烧录弹幕（$VideoEncoder → $Container）..." -ForegroundColor Gray
                # 归一化滤镜必须在 ass 之前：先锁定帧尺寸，再让 libass 按固定画布绘制
                $vfFull = if ($vfNorm) { "$vfNorm,ass=danmaku.ass" } else { 'ass=danmaku.ass' }
                $ffArgs = @(
                    '-hide_banner', '-nostdin', '-stats',
                    '-i', $mutedPath,
                    '-vf', $vfFull
                ) + $vArgs + $containerArgs + @(
                    '-c:a', 'copy',
                    '-max_muxing_queue_size', '1024',
                    '-y', $danmakuPath
                )
                $code = Invoke-External -Exe $FFmpegPath -Arguments $ffArgs -WorkingDirectory $workDir
            }
            else {
                $code = -1
            }

            $burnOk = ($prepOk -and $code -eq 0)
            if (-not $DryRun -and -not (Test-Path -LiteralPath $danmakuPath)) { $burnOk = $false }
            if (-not $burnOk) {
                if ($prepOk) {
                    Write-Err "弹幕烧录失败（退出码 $code）"
                }
                else {
                    Write-Err '弹幕烧录已跳过：烧录前的准备（见上面的错误）没成功'
                }
                $failed++
                [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '烧录失败'; Output = $mutedFinal; Extras = @() })
                continue
            }

            Write-Produced $danmakuPath
            $finalPath = $danmakuPath

            # -KeepAss：把 xml 转换出来的 ASS 也留一份（与成品同名，便于检查/手工微调）
            if ($KeepAss -and $hasXml) {
                $assOut = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}${DANMAKU_TAG}.ass"
                if ($DryRun) {
                    Write-Host "   [DryRun] 将保留转换出的 ASS $(Split-Path -Leaf $assOut)" -ForegroundColor DarkCyan
                }
                else {
                    Copy-Item -LiteralPath $workAss -Destination $assOut -Force
                    Write-Host "   已保留转换出的 ASS $(Split-Path -Leaf $assOut)" -ForegroundColor DarkGray
                }
                $extras += $assOut
            }

            # 中间产物的去留
            if ($KeepMuted) {
                # 保留仅消音文件，并同样按平台加前缀
                $keptMuted = Set-MutedName -From $mutedPath -To $mutedFinal
                if ($DryRun) {
                    Write-Host "   [DryRun] 将保留仅消音文件 $(Split-Path -Leaf $keptMuted)" -ForegroundColor DarkCyan
                }
                else {
                    Write-Host "   已保留仅消音文件 $(Split-Path -Leaf $keptMuted)" -ForegroundColor DarkGray
                }
                $extras += $keptMuted
            }
            elseif (-not $DryRun) {
                Remove-Item -LiteralPath $mutedPath -Force
                Write-Host "   已删除中间产物 $(Split-Path -Leaf $mutedPath)" -ForegroundColor DarkGray
            }
        }
        finally {
            if (-not $DryRun -and (Test-Path -LiteralPath $workDir)) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $status = '消音+弹幕'
    }
    else {
        # 不烧弹幕：消音版本身就是成品，按平台前缀整理好
        if ($SkipDanmaku) {
            if ($hasAss -or $hasXml) {
                $whichDm = Split-Path -Leaf $(if ($hasAss) { $assPath } else { $xmlPath })
                Write-Skip "指定 -SkipDanmaku，不做弹幕烧录（已忽略 $whichDm）"
            }
            else {
                Write-Skip '指定 -SkipDanmaku，不做弹幕烧录'
            }
        }
        else {
            Write-Skip "没有同名弹幕文件（.ass / .xml），成品即消音版"
        }

        $mutedPath = Set-MutedName -From $mutedPath -To $mutedFinal
        $finalPath = $mutedPath
        if ($DryRun) {
            Write-Host "   [DryRun] 成品为 $(Split-Path -Leaf $finalPath)" -ForegroundColor DarkCyan
        }
        $status = '仅消音'
    }

    [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = $status; Output = $finalPath; Extras = $extras })
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '===== 处理汇总 =====' -ForegroundColor Magenta
foreach ($r in $results) {
    $color = switch -Wildcard ($r.Status) { '*失败*' { 'Red' } '缺少*' { 'Red' } '仅消音' { 'Yellow' } '已存在*' { 'DarkGray' } default { 'Green' } }
    Write-Host ("  [{0}] {1}" -f $r.Status, $r.File) -ForegroundColor $color
    Write-Host ("         → {0}" -f $r.Output) -ForegroundColor DarkGray
    foreach ($ex in @($r.Extras)) {
        if ($ex) { Write-Host ("         + {0}" -f $ex) -ForegroundColor DarkGray }
    }
}

if ($failed -gt 0) {
    Write-Host ''
    Write-Host "$failed 个文件处理失败。" -ForegroundColor Red
}
else {
    Write-Host ''
    Write-Host '全部完成。' -ForegroundColor Green
}

# ---------- 异常兜底提示（放在最底部）----------
# 处理失败的文件也算异常，一并汇总，避免只盯着画布那几项。
foreach ($r in $results) {
    if ($r.Status -match '失败|缺少') {
        [void]$anomalies.Add([pscustomobject]@{
                Kind   = '处理失败'
                File   = $r.File
                Detail = "状态：$($r.Status)"
            })
    }
}

Write-Host ''
if ($anomalies.Count -gt 0) {
    Write-Host '⚠ 本场直播有异常情况，请留意：' -ForegroundColor Yellow
    foreach ($a in $anomalies) {
        Write-Host ("   · [{0}] {1}" -f $a.Kind, $a.File) -ForegroundColor Yellow
        if ($a.Detail) {
            Write-Host ("     {0}" -f $a.Detail) -ForegroundColor DarkYellow
        }
    }
    # 提示语按异常类型给：只有画布类异常时才提 -OutputSize / -ExpectedRatio
    $hasGeomAnomaly = @($anomalies | Where-Object { $_.Kind -notmatch '处理失败' }).Count -gt 0
    if ($hasGeomAnomaly) {
        Write-Host '   （画布类仅为提醒：成品已按各自画布适配；可用 -OutputSize 强制尺寸、-ExpectedRatio none 关闭比例检查）' -ForegroundColor DarkGray
    }
    if ($failed -gt 0) {
        Write-Host '   （失败项请向上翻看对应文件的日志定位原因）' -ForegroundColor DarkGray
    }
}
else {
    Write-Host '本场直播未发现异常情况。' -ForegroundColor Green
}

if ($failed -gt 0) { exit 1 }
exit 0
