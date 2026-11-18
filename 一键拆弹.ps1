<#
.SYNOPSIS
    一键拆弹：对直播录播视频（FLV / TS 等）做音频消音，按来源处理弹幕，统一输出 MP4。

.DESCRIPTION
    唯一入口：自动识别抖音 / B站 / 小红书录播，按来源决定是否烧录弹幕。

      Step 1  对目录下每个录播视频（.flv / .ts）调用 beep_filter.py 消音
              → 生成 <原名>_消音版.<原扩展名>（中间产物）
      Step 2  按同名弹幕文件与素材特征识别来源：
                * 抖音（同名 .ass，DanmakuRender 录制）→ 适配画布后直接烧录
                * B站（同名 .xml，录播姬导出）→ 先用 bili_danmaku_to_ass.py 转成
                  ASS 再烧录。xml 本身不含字体信息，字体样式自动取本目录下抖音
                  ASS 的样式（字体/字号/颜色/透明度/描边，以及车道间距与滚动时长，
                  按画面面积开方等比缩放），使两个平台的成品观感保持统一
                * 小红书（录制端暂不提供弹幕）→ 不烧弹幕，把消音版转封装成 MP4
              有弹幕 → <平台前缀><原名>_消音版_弹幕版.mp4
              无弹幕 → <平台前缀><原名>_消音版.mp4

    成品与命名规则：
      * 成品默认导出为 MP4（源本就是 h264+aac，封装 mp4 无额外损失，
        且 mp4 对抖音/B站/小红书/微信等平台的上传兼容性最好）。可用 -Container 改成 mov / mkv。
      * 默认只保留最终成品，成功后自动删掉 _消音版.<原扩展名> 中间产物；
        需要留下仅消音的视频时加 -KeepMuted。
      * 按录播来源给成品文件名加前缀：抖音 → 抖音-，B站 → B站-，小红书 → 小红书-。
        前缀对「带弹幕」和「仅消音」两种成品都生效。

    要点：
      * 不修改任何原始视频 / ass / xml 文件。
      * 烧录必须重新编码视频流；音频流改为重编 AAC，并按采样重新生成连续时间戳。
        源录播文件可能带录制空洞或时间戳倒流（分段拼接/推流中断），直接 -c:a copy
        会把跳变带进成品，平台会以「该视频内部存在时间戳跳变」拒收。
        检测到这类异常时，才按源标称帧率把视频补成恒定帧率（CFR），空洞用
        重复帧/静音补齐；正常文件保持原帧率/时间戳，不做多余补帧或丢帧。
        两种情况下都保持原有播放时间轴与弹幕时间轴不变。
      * 默认自动优先使用 NVIDIA NVENC 硬件编码，不可用时回退 libx264。
      * 若某个视频没有同名弹幕文件（当前为小红书），跳过弹幕烧录，但仍把消音版
        转封装为 MP4：成品为 <平台前缀><原名>_消音版.mp4。
      * 出于过审考虑，Step 2 绝不会退回去烧录「未消音」的原片：
        找不到消音版输出时只报错跳过。
      * 弹幕正文也要过审：烧录前逐行审查要烧的那份 ASS，正文命中敏感数字的整行直接
        抹除。覆盖面按「画面上会被机器审核看到」来定，比音频侧宽得多：以
        beep_filter.py 的 TARGET_KEYWORDS（14 种，音频同源）为基础，再叠加
        danmaku_censor.py 的视觉扩展 —— 0.64 / 6.4 / 6,4 / 6·4 / 6/4 等组合、
        全角与带圈数字、以及 陆肆 / 陸肆 / 六4 / 6四 / 陆拾肆 / 捌拾玖 / 6月4日
        这类汉字（含财务体、繁体、日期）写法，都在覆盖范围内。
        抖音 ass 与 B站 xml 走同一套逻辑，-KeepAss 留下的也是审查后的版本。
        审查脚本缺失或执行失败会中止烧录，宁可不出片也不漏审。
      * 抖音 ASS 烧录前会先按视频画布做一次适配：DanmakuRender 的 PlayRes 偶尔与录播
        画布比例不一致（例如 ASS 是 1920x1080、视频是 720x1280），libass 对 x 坐标和
        字号的缩放比例不同，滚动弹幕会在还剩大半文字没滑出时提前消失。适配只改临时
        副本，不动原 ASS；比例一致时完全不动。
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
    需要重编码时的视频编码器（弹幕烧录、CFR 修复、画布归一化）：
    auto（默认，优先 nvenc）/ nvenc / x264。

.PARAMETER Quality
    编码质量，nvenc 为 -cq、x264 为 -crf，默认 23（数值越小画质越好）。

.PARAMETER Container
    成品的封装格式（带弹幕与仅消音都适用）：mp4（默认）/ mov / mkv。

.PARAMETER Platform
    录播来源，决定成品文件名前缀：auto（默认，自动判断）/
    douyin / bilibili / xiaohongshu / none。
    自动判断优先看同名弹幕文件（ass → 抖音，xml → B站），再看视频文件名、
    所在目录名与 ffprobe metadata（小红书特征含 source=xhslive、X-Xhs）；
    无同名弹幕且没有其他平台特征时按小红书处理。判断错了可以用本参数强制指定。

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
    保留「最终烧录用的那份 ASS」（与成品同名、扩展名为 .ass），便于检查或手工微调。
    默认不保留（只放在临时目录里）。保留的是**已经过正文审查**的版本——
    抖音 ass 会留一份审查后的副本，B站 xml 留的是转换结果，两者都方便核对到底烧了什么。

.PARAMETER SkipCensor
    跳过弹幕正文审查（仅调试用）。默认会逐行审查要烧录的 ASS，正文命中敏感数字的
    整行抹除；覆盖面见上文「弹幕正文也要过审」，抖音 ass 与 B站 xml 走同一套逻辑。
    想核对最终生效的关键词清单：`python danmaku_censor.py --list-keywords`

.PARAMETER SkipMute
    跳过消音，仅复用已存在的 _消音版.<原扩展名>：有弹幕就烧录，无弹幕就转封装 MP4。

.PARAMETER SkipDanmaku
    跳过弹幕烧录，只出仅消音的 MP4 成品（成品名仍按平台加前缀）。

.PARAMETER KeepMuted
    额外保留仅消音的视频文件（默认烧录成功后会删掉 _消音版 中间产物）。
    保留的文件同样按平台加前缀。

.PARAMETER Force
    强制重做：覆盖已存在的成品，并重跑消音步骤。

.PARAMETER DryRun
    只打印将执行的命令，不实际执行（不产生/删除/改名任何文件）。
    交互式控制台会在打印清单/预估后等待回车；非交互式自动继续。

.PARAMETER Yes
    DryRun 预览时跳过“按 Enter 继续”的确认。正式运行本来就不暂停。

.PARAMETER NoEstimate
    关闭启动清单里的耗时预估，同时不读取/不追加 logs\run_stats.jsonl；DryRun 也不暂停。
    已有统计文件不会被删除，只是本次不使用。

.PARAMETER HistoryRuns
    预估使用最近多少次运行的有效样本，默认 5。样本不足时用现有的全部运行；
    只有完全没有任何运行记录时才提示数据不足。首次没有统计文件时，会从
    logs\一键拆弹_*.log 回填最多 5 次运行作为初始基准。

.PARAMETER NoNotify
    全部完成后不发送 Windows 通知。默认会发送一条桌面通知
    （Windows PowerShell 5.1 用 WinRT Toast，PowerShell 7 下回退到托盘气泡）。
    -DryRun 始终不发送。

.PARAMETER LogDir
    运行日志目录，默认脚本所在目录下的 logs。
    每次正式运行生成一个 .log，记录启动参数、每个文件的处理步骤、外部命令、
    工作目录、退出码、汇总与异常。日志含本机真实路径，目录已被 .gitignore 忽略。
    -DryRun 不写日志（不产生任何文件）。

.EXAMPLE
    .\一键拆弹.ps1
    处理脚本所在目录的全部录播视频（.flv / .ts）：自动识别平台；有弹幕就烧录，无弹幕就只出消音 MP4。

.EXAMPLE
    .\一键拆弹.ps1 -Directory "D:\录播" -ModelSize large
    指定目录与模型大小。

.EXAMPLE
    .\一键拆弹.ps1 -KeepMuted
    烧录弹幕的同时，把仅消音的 _消音版 文件也留下。

.EXAMPLE
    .\一键拆弹.ps1 -SkipMute
    已经消音过的视频，只补烧弹幕（需要 _消音版 文件还在）。

.EXAMPLE
    .\一键拆弹.ps1 -DryRun
    预览将要执行的 python / ffmpeg 命令。

.EXAMPLE
    .\一键拆弹.ps1 -Platform douyin -Container mkv
    没有弹幕文件也能强制加「抖音-」前缀，并改用 mkv 封装。

.EXAMPLE
    .\一键拆弹.ps1 -Directory "D:\B站录播"
    处理 B站录播：把同名 xml 弹幕转成 ASS（字体样式取自本目录的抖音 ASS）后
    硬编码进消音版视频，成品形如 　B站-录制-xxx_消音版_弹幕版.mp4。

.EXAMPLE
    .\一键拆弹.ps1 -Directory "D:\B站录播" -Lanes 16 -ScrollDuration 12 -KeepAss
    B站弹幕很密时加宽到 16 条车道、缩短在屏时间以减少文字压叠，并保留转换出的 ASS。

.EXAMPLE
    .\一键拆弹.ps1 -Directory "D:\小红书录播" -ModelSize tiny
    处理小红书录播：没有弹幕文件时自动识别为小红书，只消音并输出
    小红书-<原名>_消音版.mp4。
#>

# 注意：#Requires 必须放在帮助块之后。放在文件最前面会让 Get-Help 认不出
# 上面的注释式帮助（只会吐出语法行），而放在这里依然会被强制执行。
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Directory,
    [string]$ModelSize = 'large',
    [ValidateSet('auto', 'nvenc', 'x264')]
    [string]$VideoEncoder = 'auto',
    [int]$Quality = 23,
    [ValidateSet('mp4', 'mov', 'mkv')]
    [string]$Container = 'mp4',
    [ValidateSet('auto', 'douyin', 'bilibili', 'xiaohongshu', 'none')]
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
    [switch]$SkipCensor,
    [switch]$SkipMute,
    [switch]$SkipDanmaku,
    [switch]$KeepMuted,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$NoEstimate,
    [int]$HistoryRuns = 5,
    [switch]$NoNotify,
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'

# 控制台按 UTF-8 输出，保证中文文件名/日志不乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = 'utf-8'

# 用于完成通知里的总耗时（不受 DryRun 是否写日志影响）
$script:RunStarted = Get-Date

# ---------- 运行日志 ----------
# 日志默认落在脚本目录下的 logs\，每次正式运行一个 .log。
# 这里把 Write-Host 包成同名函数：先调用内置 cmdlet，再把同一段文本写进日志。
# 这样脚本里原有的几十处 Write-Host 都不用改，新增输出也会自动入日志。
$script:LogWriter = $null
$script:LogPath = $null
$script:LogStarted = $null
$script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param([string]$Text)
    if (-not $script:LogWriter) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    try {
        # 按行拆开，保证多行文本每行都有时间戳
        foreach ($line in ($Text -split "\r?\n")) {
            $script:LogWriter.WriteLine("[$stamp] $line")
        }
    }
    catch {
        # 日志写不进去不能影响主流程
        try { $script:LogWriter.Dispose() } catch { }
        $script:LogWriter = $null
        Microsoft.PowerShell.Utility\Write-Host "   [警告] 日志写入失败，后续不再记录: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-Host {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [object]$Separator
    )
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    if ($script:LogWriter) {
        $sep = if ($PSBoundParameters.ContainsKey('Separator')) { "$Separator" } else { ' ' }
        $text = ($Object | ForEach-Object { "$_" }) -join $sep
        Write-Log $text
    }
}

function Initialize-Log {
    param([string]$LogDirectory, [string]$Prefix)
    if ($DryRun) {
        Write-Host '  日志     : DryRun 不写日志' -ForegroundColor DarkGray
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }
        $LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $path = Join-Path $LogDirectory "${Prefix}_${stamp}.log"
        # 同一秒内重跑时避免覆盖/追加到同一份日志
        $i = 2
        while (Test-Path -LiteralPath $path) {
            $path = Join-Path $LogDirectory "${Prefix}_${stamp}_${i}.log"
            $i++
        }
        $writer = New-Object System.IO.StreamWriter($path, $true, $script:LogEncoding)
        $writer.AutoFlush = $true
        $script:LogWriter = $writer
        $script:LogPath = $path
        $script:LogStarted = Get-Date
        Write-Log '===== 一键拆弹运行日志 ====='
        Write-Log "开始时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "脚本: $PSCommandPath"
        Write-Log "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        Write-Host "  日志     : $path" -ForegroundColor DarkGray
    }
    catch {
        $script:LogWriter = $null
        $script:LogPath = $null
        Microsoft.PowerShell.Utility\Write-Host "   [警告] 无法创建运行日志（$($_.Exception.Message)），本次不写日志" -ForegroundColor Yellow
    }
}

function Close-Log {
    param([int]$ExitCode = 0)
    if (-not $script:LogWriter) { return }
    try {
        Write-Log "结束时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        if ($script:LogStarted) {
            $sec = [math]::Round(((Get-Date) - $script:LogStarted).TotalSeconds, 1)
            Write-Log "总耗时: ${sec}s"
        }
        Write-Log "退出码: $ExitCode"
        $script:LogWriter.Flush()
        $script:LogWriter.Dispose()
    }
    catch { }
    finally {
        $script:LogWriter = $null
        $script:LogPath = $null
    }
}

# ---------- 运行统计（耗时预估基准） ----------
# 一行一次运行的 JSONL，默认放在 logs\run_stats.jsonl。
# 只记录文件名（不含目录）、视频秒数、大小、各阶段耗时、模型/编码器与时间戳；
# 不写主机名、用户名、IP、MAC 或完整路径——logs\ 已在 .gitignore 里整目录忽略。
# 读取时逐行解析，坏行/空行直接跳过；写入失败只警告，不影响主流程。
$script:RunStatsKeep = 50

function Get-RunStatsPath {
    param([string]$LogDirectory)
    if (-not $LogDirectory) { $LogDirectory = $LogDir }
    if (-not $LogDirectory) { return $null }
    return (Join-Path $LogDirectory 'run_stats.jsonl')
}

function Read-RunStats {
    param([string]$Path)
    $runs = New-Object System.Collections.ArrayList
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
            if (-not $line -or -not $line.Trim()) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($null -ne $obj) { [void]$runs.Add($obj) }
            }
            catch {
                # 单行损坏（手工编辑/写入中断）不应该让整份基准失效
                Write-Log "运行统计有坏行，已跳过: $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Warn "读取运行统计失败（$($_.Exception.Message)），本次按无历史基准处理"
    }
    return @($runs)
}

function New-RunStatsRecord {
    param(
        [datetime]$StartedAt,
        [datetime]$EndedAt,
        [string]$Model,
        [string]$Encoder,
        [string]$Source,          # live / backfill
        [object[]]$Files,
        [double]$EstimateSeconds = 0
    )
    $fileList = @()
    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        $fileList += [pscustomobject]@{
            # 只留文件名：日志/统计文件里不出现真实目录
            Name          = [System.IO.Path]::GetFileName([string]$f.Name)
            DurationSec   = [math]::Round([double]$f.DurationSec, 3)
            SizeBytes     = [long]$f.SizeBytes
            MuteSec       = [math]::Round([double]$f.MuteSec, 1)
            BurnSec       = [math]::Round([double]$f.BurnSec, 1)
            RemuxSec      = [math]::Round([double]$f.RemuxSec, 1)
            ProbeSec      = [math]::Round([double]$f.ProbeSec, 1)
            TotalSec      = [math]::Round([double]$f.TotalSec, 1)
            Mode          = [string]$f.Mode
            Failed        = [bool]$f.Failed
        }
    }
    $actualSeconds = 0.0
    foreach ($f in @($fileList)) { $actualSeconds += [double]$f.TotalSec }
    return [pscustomobject]@{
        Version         = 1
        Source          = $Source
        StartedAt       = $StartedAt.ToString('o')
        EndedAt         = $EndedAt.ToString('o')
        Model           = $Model
        Encoder         = $Encoder
        EstimateSeconds = [math]::Round($EstimateSeconds, 1)
        ActualSeconds   = [math]::Round($actualSeconds, 1)
        Files           = @($fileList)
    }
}

function Add-RunStatsRecord {
    param(
        [string]$Path,
        [object]$Record,
        [int]$Keep = $script:RunStatsKeep
    )
    if (-not $Path -or -not $Record) { return $false }
    $tmp = $Path + '.tmp'
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = $Record | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $script:LogEncoding)

        # 只保留最近 N 条；重写时先写临时文件再替换，避免中途失败留下半份文件
        $lines = @([System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8))
        if ($lines.Count -gt $Keep) {
            $tail = $lines[($lines.Count - $Keep)..($lines.Count - 1)]
            [System.IO.File]::WriteAllLines($tmp, $tail, $script:LogEncoding)
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Warn "写入运行统计失败（$($_.Exception.Message)），不影响本次处理"
        return $false
    }
}

# 运行结束写一条 live 记录；DryRun / -NoEstimate / 没有实际处理的文件时不写。
function Save-RunStats {
    param(
        [string]$Path,
        [object[]]$Files,
        [string]$Model,
        [string]$Encoder,
        [datetime]$StartedAt,
        [datetime]$EndedAt,
        [double]$EstimateSeconds = 0
    )
    if ($DryRun -or $NoEstimate) { return $false }
    if (-not $Path -or @($Files).Count -eq 0) { return $false }
    $record = New-RunStatsRecord -StartedAt $StartedAt -EndedAt $EndedAt -Model $Model -Encoder $Encoder `
        -Source 'live' -Files @($Files) -EstimateSeconds $EstimateSeconds
    return (Add-RunStatsRecord -Path $Path -Record $record -Keep $script:RunStatsKeep)
}

function Format-DurationText {
    param([double]$Seconds)
    if ($Seconds -le 0) { return '00:00:00' }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    $hours = [math]::Floor($ts.TotalHours)
    return ('{0:00}:{1:00}:{2:00}' -f $hours, $ts.Minutes, $ts.Seconds)
}

function Format-SizeText {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-EtaText {
    param([double]$Seconds)
    if ($Seconds -le 0) { return '0 秒' }
    $total = [int][math]::Round($Seconds)
    $h = [int][math]::Floor($total / 3600)
    $m = [int][math]::Floor(($total % 3600) / 60)
    $s = $total % 60
    if ($h -gt 0) { return "$h 小时 $m 分" }
    if ($m -gt 0) { return "$m 分 $s 秒" }
    return "$s 秒"
}

# 从历史运行日志回填最近几次「有效运行」，替代用户先手动跑 3 次收集基准。
# 日志格式见 Write-Log：每行 [HH:mm:ss] 文本；每个文件以 "── [文件名]" 开头，
# Step 1 行到 "_消音版.<扩展名> 已生成" 是消音阶段，Step 2 行到最终成品 "已生成"
# 是烧录/转封装阶段，段开始到 Step 1 是画布探测等固定开销。
# 只回填有视频时长、有阶段耗时且未失败/未跳过的文件；解析不出来的日志跳过。
function Import-LegacyRunStats {
    param(
        [string]$LogDirectory,
        [int]$WantedRuns = 5,
        [int]$MaxLogs = 12
    )
    $runs = New-Object System.Collections.ArrayList
    if (-not $LogDirectory -or -not (Test-Path -LiteralPath $LogDirectory)) { return @() }

    # 结束一个文件段并把它转成统计样本（哈希表按引用修改）
    $finishFile = {
        param($f, $endTime, $list)
        if (-not $f) { return }
        if (-not $endTime) { $endTime = $f.StartTime }
        $f.EndTime = $endTime
        $f.TotalSec = [math]::Max(0.0, ($endTime - $f.StartTime).TotalSeconds)

        if ($f.MuteStart -and $f.MuteEnd) {
            $f.MuteSec = [math]::Max(0.0, ($f.MuteEnd - $f.MuteStart).TotalSeconds)
        }
        if ($f.Step2Start) {
            $finishEnd = if ($f.FinishEnd) { $f.FinishEnd } else { $endTime }
            $finishSec = [math]::Max(0.0, ($finishEnd - $f.Step2Start).TotalSeconds)
            if ($f.Mode -eq 'burn') { $f.BurnSec = $finishSec }
            elseif ($f.Mode -eq 'remux') { $f.RemuxSec = $finishSec }
        }
        $probeStart = if ($f.MuteStart) { $f.MuteStart } elseif ($f.Step2Start) { $f.Step2Start } else { $null }
        if ($probeStart) {
            $f.ProbeSec = [math]::Max(0.0, ($probeStart - $f.StartTime).TotalSeconds)
        }

        $stageTotal = [double]$f.MuteSec + [double]$f.BurnSec + [double]$f.RemuxSec
        if ($f.DurationSec -gt 0 -and -not $f.Failed -and -not $f.Skip -and $stageTotal -gt 0) {
            [void]$list.Add([pscustomobject]@{
                    Name        = $f.Name
                    DurationSec = [double]$f.DurationSec
                    SizeBytes   = [long]0
                    MuteSec     = [double]$f.MuteSec
                    BurnSec     = [double]$f.BurnSec
                    RemuxSec    = [double]$f.RemuxSec
                    ProbeSec    = [double]$f.ProbeSec
                    TotalSec    = [double]$f.TotalSec
                    Mode        = [string]$f.Mode
                    Failed      = $false
                })
        }
    }

    try {
        $logFiles = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '一键拆弹_*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First $MaxLogs)

    foreach ($log in $logFiles) {
        # 文件名带运行开始时间，先用它做日期基准，避免日志头尚未解析时跨天判断出错
        $nameMatch = [regex]::Match($log.Name, '^一键拆弹_(\d{8})_(\d{6})')
        if (-not $nameMatch.Success) { continue }
        $startedAt = [datetime]::MinValue
        $parsedNameTime = [datetime]::TryParseExact(
            $nameMatch.Groups[1].Value + $nameMatch.Groups[2].Value,
            'yyyyMMddHHmmss',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$startedAt)
        if (-not $parsedNameTime) { continue }

        $baseDate = $startedAt.Date
        $endedAt = $null
        $model = 'unknown'
        $encoder = 'unknown'
        $current = $null
        $files = New-Object System.Collections.ArrayList
        $lastTime = $null

        try {
            foreach ($line in [System.IO.File]::ReadLines($log.FullName, [System.Text.Encoding]::UTF8)) {
                $mTime = [regex]::Match($line, '^\[(\d{2}):(\d{2}):(\d{2})\]\s?(.*)$')
                if (-not $mTime.Success) { continue }
                $t = $baseDate.AddHours([int]$mTime.Groups[1].Value).
                    AddMinutes([int]$mTime.Groups[2].Value).
                    AddSeconds([int]$mTime.Groups[3].Value)
                # 日志跨天：时间倒退就按第二天算
                if ($null -ne $lastTime -and $t -lt $lastTime) { $t = $t.AddDays(1) }
                $lastTime = $t
                $text = $mTime.Groups[4].Value

                # ---- 运行级元数据 ----
                if ($text -match '^\s*开始时间:\s*(.+)$') {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($Matches[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                        $startedAt = $parsed
                        $baseDate = $parsed.Date
                    }
                    continue
                }
                if ($text -match '^\s*结束时间:\s*(.+)$') {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($Matches[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                        $endedAt = $parsed
                    }
                    continue
                }
                if ($text -match '^\s*模型\s*:\s*([A-Za-z0-9_.-]+)') { $model = $Matches[1]; continue }
                if ($text -match '^\s*编码器\s*:\s*([A-Za-z0-9_.-]+)') { $encoder = $Matches[1]; continue }

                # ---- 文件段边界 ----
                if ($text -match '^\s*──\s*\[(.+)\]\s*$') {
                    if ($current) { & $finishFile $current $t $files }
                    $current = @{
                        Name        = $Matches[1]
                        StartTime   = $t
                        EndTime     = $null
                        MuteStart   = $null
                        MuteEnd     = $null
                        Step2Start  = $null
                        FinishEnd   = $null
                        MuteSec     = 0.0
                        BurnSec     = 0.0
                        RemuxSec    = 0.0
                        ProbeSec    = 0.0
                        TotalSec    = 0.0
                        DurationSec = 0.0
                        Mode        = ''
                        Failed      = $false
                        Skip        = $false
                    }
                    continue
                }
                if ($text -match '^\s*=====\s*处理汇总') {
                    if ($current) { & $finishFile $current $t $files; $current = $null }
                    continue
                }
                if (-not $current) { continue }

                # ---- 文件段内的阶段时间点 ----
                if ($text -match '^\s*Step 1 消音中') {
                    $current.MuteStart = $t
                    continue
                }
                if ($text -match '^\s*Step 2\s+(烧录弹幕|仅消音转封装)') {
                    $current.Step2Start = $t
                    $current.Mode = if ($Matches[1] -eq '烧录弹幕') { 'burn' } else { 'remux' }
                    continue
                }
                if ($text -match '^\s*\[OK\]\s+已生成\s+(.+)$') {
                    $generated = $Matches[1].Trim()
                    # 中间产物扩展名跟随源容器（.flv / .ts 等）；只认 "_消音版.<扩展名>"，
                    # 不会误匹配最终成品 "_消音版_弹幕版.mp4"。
                    if ($generated -match '_消音版\.[^.]+$') {
                        $current.MuteEnd = $t
                    }
                    elseif ($current.Step2Start -and -not $current.FinishEnd) {
                        $current.FinishEnd = $t
                    }
                    continue
                }
                if ($text -match '^\s*Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)') {
                    if ($current.DurationSec -le 0) {
                        $current.DurationSec = [double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3]
                    }
                    continue
                }
                if ($text -match '已存在成品') { $current.Skip = $true; continue }
                if ($text -match '^\s*\[失败\]') { $current.Failed = $true; continue }
            }
        }
        catch {
            Write-Log "解析历史日志失败（$($log.Name)）：$($_.Exception.Message)"
        }
        if ($current) {
            $endForFile = if ($lastTime) { $lastTime } else { $current.StartTime }
            & $finishFile $current $endForFile $files
            $current = $null
        }

        if ($files.Count -gt 0) {
            $endForRecord = if ($endedAt) { $endedAt } elseif ($lastTime) { $lastTime } else { $startedAt }
            $run = New-RunStatsRecord -StartedAt $startedAt -EndedAt $endForRecord `
                -Model $model -Encoder $encoder -Source 'backfill' -Files @($files)
            [void]$runs.Add($run)
            if ($runs.Count -ge $WantedRuns) { break }
        }
    }
    }
    catch {
        Write-Log "回填历史日志失败：$($_.Exception.Message)"
    }
    return @($runs)
}

# 读取耗时基准；只有统计文件不存在或没有任何有效记录时，才从历史日志回填一次。
# 一旦有任意一条有效记录就不再解析日志——删除 run_stats.jsonl 即可重置基准。
function Initialize-RunStats {
    param(
        [string]$Path,
        [string]$LogDirectory,
        [int]$WantedRuns = 5
    )
    try {
        $existing = @(Read-RunStats -Path $Path)
        if ($existing.Count -gt 0) { return $existing }

        if (-not $LogDirectory) { return @() }
        $legacy = @(Import-LegacyRunStats -LogDirectory $LogDirectory -WantedRuns $WantedRuns)
        if ($legacy.Count -eq 0) {
            Write-Host '  运行统计: 没有可用的历史运行记录，本次无法评估耗时（完成后会自动建立基准）' -ForegroundColor Yellow
            return @()
        }

        if ($DryRun) {
            Write-Host "  运行统计: DryRun 不落盘，临时从历史日志回填 $($legacy.Count) 次运行" -ForegroundColor DarkGray
            return $legacy
        }

        # Import 按时间倒序返回；统计文件按旧 → 新追加，便于人工查看
        $written = 0
        for ($i = $legacy.Count - 1; $i -ge 0; $i--) {
            if (Add-RunStatsRecord -Path $Path -Record $legacy[$i] -Keep $script:RunStatsKeep) {
                $written++
            }
        }
        if ($written -gt 0) {
            Write-Host "  运行统计: 已从历史日志回填 $written 次运行作为初始基准" -ForegroundColor DarkGray
        }
        else {
            Write-Warn '历史日志已解析，但运行统计没能写入；本次仍使用临时基准，下次启动会重试'
        }
        return $legacy
    }
    catch {
        Write-Warn "初始化运行统计失败（$($_.Exception.Message)），本次不做耗时预估"
        return @()
    }
}

# 用最近 N 次运行的同阶段样本算加权倍率，再按本次每个文件的时长估算。
# 只要有有效样本就用，不按模型/编码器/CUDA/CPU 过滤，文案里也不显示配置。
function Get-RunEta {
    param(
        [object[]]$Plans,
        [object[]]$History,
        [int]$HistoryRuns = 5
    )

    # 1. 只保留有有效文件样本的运行，按开始时间倒序取最近 N 次
    $runs = @()
    foreach ($r in @($History)) {
        if (-not $r) { continue }
        $files = @()
        foreach ($f in @($r.Files)) {
            if (-not $f) { continue }
            if ([bool]$f.Failed) { continue }
            $duration = [double]$f.DurationSec
            if ($duration -le 0) { continue }
            $mute = [double]$f.MuteSec
            $burn = [double]$f.BurnSec
            $remux = [double]$f.RemuxSec
            if (($mute + $burn + $remux) -le 0) { continue }
            $files += [pscustomobject]@{
                DurationSec = $duration
                MuteSec     = $mute
                BurnSec     = $burn
                RemuxSec    = $remux
                ProbeSec    = [double]$f.ProbeSec
            }
        }
        if ($files.Count -eq 0) { continue }
        $started = [datetimeoffset]::MinValue
        $parsed = [datetimeoffset]::TryParse(
            [string]$r.StartedAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$started)
        if (-not $parsed) { $started = [datetimeoffset]::MinValue }
        $runs += [pscustomobject]@{
            StartedAt = $started
            Files     = $files
        }
    }
    $take = [math]::Max(1, $HistoryRuns)
    $runs = @($runs | Sort-Object StartedAt -Descending | Select-Object -First $take)

    # 2. 汇总阶段样本：每阶段单独算 Σ耗时 / Σ视频秒
    $samples = @()
    foreach ($run in $runs) {
        foreach ($f in @($run.Files)) { $samples += $f }
    }
    $muteDur = 0.0; $muteSec = 0.0
    $burnDur = 0.0; $burnSec = 0.0
    $remuxDur = 0.0; $remuxSec = 0.0
    $probeValues = @()
    foreach ($s in $samples) {
        if ($s.MuteSec -gt 0) { $muteDur += $s.DurationSec; $muteSec += $s.MuteSec }
        if ($s.BurnSec -gt 0) { $burnDur += $s.DurationSec; $burnSec += $s.BurnSec }
        if ($s.RemuxSec -gt 0) { $remuxDur += $s.DurationSec; $remuxSec += $s.RemuxSec }
        if ($s.ProbeSec -gt 0) { $probeValues += $s.ProbeSec }
    }
    $muteRate = if ($muteDur -gt 0) { $muteSec / $muteDur } else { $null }
    $burnRate = if ($burnDur -gt 0) { $burnSec / $burnDur } else { $null }
    $remuxRate = if ($remuxDur -gt 0) { $remuxSec / $remuxDur } else { $null }

    # 固定开销取中位数，避免一次卡顿把每文件开销抬高
    $probeFixed = 0.0
    if ($probeValues.Count -gt 0) {
        $sorted = @($probeValues | Sort-Object)
        $mid = [int][math]::Floor($sorted.Count / 2)
        if ($sorted.Count % 2 -eq 0) {
            $probeFixed = ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
        }
        else {
            $probeFixed = [double]$sorted[$mid]
        }
    }

    # 3. 每个本次文件的预计
    $items = @()
    $totalEta = 0.0
    $totalDuration = 0.0
    $hasPartial = $false
    foreach ($p in @($Plans)) {
        if (-not $p) { continue }
        $eta = 0.0
        $missing = @()
        $status = 'ok'
        if ($p.Exists) {
            $status = 'skip'
        }
        elseif ($p.MissingMuted) {
            $status = 'fail'
        }
        elseif ([double]$p.DurationSec -le 0) {
            $status = 'unknown'
        }
        elseif ($samples.Count -eq 0) {
            # 完全没有可用样本：不进入阶段累加，避免重复提示“缺各阶段样本”
            $status = 'unknown'
            $totalDuration += [double]$p.DurationSec
        }
        else {
            $eta += $probeFixed
            if ($p.NeedMute) {
                if ($null -ne $muteRate) { $eta += [double]$p.DurationSec * $muteRate }
                else { $missing += '消音' }
            }
            if ($p.Mode -eq 'burn') {
                if ($null -ne $burnRate) { $eta += [double]$p.DurationSec * $burnRate }
                else { $missing += '烧录' }
            }
            elseif ($p.Mode -eq 'remux') {
                if ($null -ne $remuxRate) { $eta += [double]$p.DurationSec * $remuxRate }
                else { $missing += '转封装' }
            }
            if ($missing.Count -gt 0) {
                $status = 'partial'
                $hasPartial = $true
            }
            $totalEta += $eta
            $totalDuration += [double]$p.DurationSec
        }
        $items += [pscustomobject]@{
            Plan       = $p
            EtaSeconds = $eta
            Status     = $status
            Missing    = @($missing)
        }
    }

    return [pscustomobject]@{
        RunsUsed             = $runs.Count
        HistoryRuns          = $take
        FilesUsed            = $samples.Count
        MuteRate             = $muteRate
        BurnRate             = $burnRate
        RemuxRate            = $remuxRate
        ProbeFixed           = $probeFixed
        Items                = @($items)
        TotalEtaSeconds      = $totalEta
        TotalDurationSec     = $totalDuration
        HasPartial           = $hasPartial
        HasSamples           = ($samples.Count -gt 0)
    }
}

# 基准说明：只用运行次数和文件样本数，不显示模型/编码器等配置。
# 没有可用样本时说清“数据不足，无法评估”，不猜默认速度。
function Get-EtaBasisText {
    param([object]$Eta)
    if (-not $Eta -or -not $Eta.HasSamples) {
        return '数据不足：本地没有可用的运行记录，本次无法评估耗时（完成后会自动开始积累基准）'
    }

    $parts = @()
    $parts += "最近 $($Eta.RunsUsed) 次运行"
    $parts += "$($Eta.FilesUsed) 个文件样本"
    $text = $parts -join '，'

    if ($Eta.RunsUsed -lt $Eta.HistoryRuns -or $Eta.FilesUsed -lt 3) {
        $text += "（样本有限：$($Eta.RunsUsed) 次运行 / $($Eta.FilesUsed) 个文件，按现有样本估算）"
    }
    if ($Eta.HasPartial) {
        $text += '；部分阶段缺少样本，预计值不完整'
    }
    return $text
}

# 启动清单：每个文件一行，末尾合计和基准说明。正式运行只打印，不在这里暂停。
function Write-EstimateList {
    param(
        [object[]]$Plans,
        [object]$Eta,
        [string]$BasisText
    )
    Write-Host ''
    Write-Host '===== 本次待处理 =====' -ForegroundColor Magenta

    $items = if ($Eta) { @($Eta.Items) } else { @() }
    $hasBasis = ($Eta -and $Eta.HasSamples)
    $idx = 0
    foreach ($p in @($Plans)) {
        $idx++
        $item = if ($idx -le $items.Count) { $items[$idx - 1] } else { $null }

        $platformText = switch ($p.Plat.Key) {
            'douyin' { '抖音' }
            'bilibili' { 'B站' }
            'xiaohongshu' { '小红书' }
            default { '未知来源' }
        }
        $stageText = if ($p.Mode -eq 'burn') {
            if ($p.NeedMute) { '消音+烧录' } else { '仅烧录' }
        }
        else {
            if ($p.NeedMute) { '消音+转封装' } else { '仅转封装' }
        }

        $durationText = if ($p.DurationSec -gt 0) { Format-DurationText $p.DurationSec } else { '--:--:--' }
        $sizeText = if ($p.SizeBytes -gt 0) { Format-SizeText $p.SizeBytes } else { '--' }

        $etaText = '—'
        $note = ''
        $color = 'Gray'
        if ($p.Exists) {
            $note = '已存在成品，跳过'
            $color = 'DarkGray'
        }
        elseif ($p.MissingMuted) {
            $note = '缺少消音版，将失败'
            $color = 'Red'
        }
        elseif ($p.DurationSec -le 0) {
            $note = '时长未知，无法预估'
            $color = 'Yellow'
        }
        elseif (-not $hasBasis) {
            $note = '数据不足，无法评估'
            $color = 'Yellow'
        }
        elseif ($item -and $item.Status -ne 'skip' -and $item.Status -ne 'fail' -and $item.Status -ne 'unknown') {
            $etaText = Format-EtaText $item.EtaSeconds
            if ($item.Status -eq 'partial') {
                $note = "缺 $($item.Missing -join '/') 样本"
                $color = 'Yellow'
            }
        }

        $line = "  {0}. {1}  [{2}, {3}, {4}/{5}]  预计 {6}" -f $idx, $p.Flv.Name, $durationText, $sizeText, $platformText, $stageText, $etaText
        if ($note) { $line += "（$note）" }
        Write-Host $line -ForegroundColor $color
    }

    $pendingCount = @($Plans | Where-Object { -not $_.Exists -and -not $_.MissingMuted }).Count
    if ($pendingCount -eq 0) {
        Write-Host ''
        Write-Host '  合计: 本次没有需要处理的文件（全部跳过/失败）' -ForegroundColor Cyan
    }
    else {
        if ($Eta) {
            $totalDuration = [double]$Eta.TotalDurationSec
        }
        else {
            $totalDuration = @($Plans | ForEach-Object {
                    if ($_.DurationSec -gt 0 -and -not $_.Exists -and -not $_.MissingMuted) { [double]$_.DurationSec }
                }) | Measure-Object -Sum
            $totalDuration = $totalDuration.Sum
        }
        $totalEtaText = if ($hasBasis) { Format-EtaText $Eta.TotalEtaSeconds } elseif ($Eta) { '无法评估（数据不足）' } else { '—' }
        Write-Host ''
        Write-Host ("  合计: {0} 个文件，视频 {1}，预计处理 {2}" -f @($Plans).Count, (Format-DurationText $totalDuration), $totalEtaText) -ForegroundColor Cyan
        if ($Eta -and $Eta.HasPartial) {
            Write-Host '  注意: 部分阶段缺少样本，预计值不完整' -ForegroundColor Yellow
        }
    }
    if ($BasisText) {
        Write-Host "  基准: $BasisText" -ForegroundColor DarkGray
    }
}

# 运行结束对比预估/实际（按非失败文件的 TotalSec 求和），帮助判断基准是否还准。
# Write-Host 包装会把这行同时写进运行日志。
function Write-EtaComparison {
    param(
        [object]$Eta,
        [object[]]$FileStats
    )
    if (-not $Eta -or -not $Eta.HasSamples) { return }
    $actual = @($FileStats | Where-Object { -not $_.Failed } | Measure-Object -Property TotalSec -Sum).Sum
    if ($null -eq $actual) { $actual = 0.0 }
    $estimate = [double]$Eta.TotalEtaSeconds
    if ($estimate -le 0 -or $actual -le 0) { return }
    $diff = ($actual - $estimate) / $estimate * 100
    $sign = if ($diff -ge 0) { '+' } else { '' }
    Write-Host ("  耗时对比: 预估 {0} / 实际 {1}（误差 {2}{3}%）" -f (Format-EtaText $estimate), (Format-EtaText $actual), $sign, [math]::Round($diff, 1)) -ForegroundColor DarkGray
}

# 未捕获的终止错误也写进日志（记录后保持原有终止行为）
trap {
    Write-Log "脚本异常终止: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
    Close-Log -ExitCode 1
    throw
}

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
# 待处理的录播容器。录制软件绝大多数时候出 FLV，极个别情况会出 TS；
# 两者走同一条流水线。以后要加别的格式，只在这里追加扩展名即可。
$VideoExtensions = @('.flv', '.ts')
# 平台前缀表
$PlatformPrefix = @{
    douyin       = '抖音-'
    bilibili     = 'B站-'
    xiaohongshu  = '小红书-'
    none         = ''
}
# 编码器质量参数：nvenc 用 -cq，x264 用 -crf
$EncoderArgs = @{
    nvenc = @('-c:v', 'h264_nvenc', '-preset', 'p5', '-rc', 'vbr', '-b:v', '0', '-pix_fmt', 'yuv420p')
    x264  = @('-c:v', 'libx264', '-preset', 'medium', '-pix_fmt', 'yuv420p')
}
# B站 xml 弹幕 → ASS 的转换脚本
$BiliConverterName = 'bili_danmaku_to_ass.py'
# 弹幕正文审查（命中敏感数字的整行抹除；关键词表见 danmaku_censor.py）
$CensorScriptName = 'danmaku_censor.py'
# 弹幕画布适配（ASS 的 PlayRes 与视频画布比例不一致时重排坐标与字号）
$FitScriptName = 'ass_canvas_fit.py'

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
function Write-Err([string]$Text) { $script:FileFailed = $true; Write-Host "   [失败] $Text" -ForegroundColor Red }

# ---------- 完成通知 ----------
# 全部处理结束后走 Windows 10/11 通知渠道发一条消息。
# 优先 BurntToast（如果装过）→ WinRT Toast（Windows PowerShell 5.1 可用）→
# 托盘气泡（PowerShell 7 / WinRT 不可用时）。任何一步失败都静默跳过，
# 不影响主流程和退出码；-DryRun 与 -NoNotify 下不发送。
function Send-CompletionNotification {
    param(
        [string]$Title,
        [string]$Message
    )
    if ($DryRun -or $NoNotify) { return }

    # 1) BurntToast（可选模块）
    try {
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
            Write-Host '   [通知] 已通过 BurntToast 发送完成通知' -ForegroundColor DarkGray
            return
        }
    }
    catch { }

    # 2) WinRT Toast（Windows PowerShell 5.1）
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        [void]$texts.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$texts.Item(1).AppendChild($xml.CreateTextNode($Message))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)

        # 常见 PowerShell 的 AppUserModelID；不同安装方式可能不同，逐个尝试。
        $appIds = @(
            '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',
            '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\PowerShell\7\pwsh.exe',
            'Microsoft.Windows.PowerShell'
        )
        foreach ($appId in $appIds) {
            try {
                [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
                Write-Host '   [通知] 已通过 Windows Toast 发送完成通知' -ForegroundColor DarkGray
                return
            }
            catch { }
        }
    }
    catch { }

    # 3) 托盘气泡（PowerShell 7 等 WinRT 不可用的场景）
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Message
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000)
        Write-Host '   [通知] 已通过托盘气泡发送完成通知' -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 1500
        $notify.Dispose()
    }
    catch {
        Write-Warn '完成通知发送失败（不影响处理结果）'
    }
}

function Format-Argv {
    param([string]$Exe, [string[]]$Arguments)
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '[\s&()]') { '"' + $_ + '"' } else { $_ }
    }
    return ($Exe + ' ' + ($quoted -join ' '))
}

# 读取 ffmpeg -report 生成的新报告，追加到主日志。
# 报告是命令结束后才读的，所以不影响控制台 stderr 的实时显示。
function Write-FfmpegReport {
    param(
        [string]$WorkingDirectory,
        [string[]]$BeforeFiles
    )
    try {
        $newReports = @(
            Get-ChildItem -LiteralPath $WorkingDirectory -Filter 'ffmpeg-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $BeforeFiles -notcontains $_.Name } |
                Sort-Object LastWriteTime -Descending
        )
        if ($newReports.Count -eq 0) {
            Write-Log '  [ffmpeg 报告] 未找到新生成的 ffmpeg-*.log，详细输出仅见控制台'
            return
        }
        $report = $newReports[0]
        $text = [System.IO.File]::ReadAllText($report.FullName, [System.Text.Encoding]::UTF8)
        $lines = $text -split "\r?\n|\r"
        $kept = New-Object System.Collections.Generic.List[string]
        $lastFrame = ''
        $lastBlank = $false
        foreach ($line in $lines) {
            $trimmed = $line.TrimEnd()
            if ($trimmed -match '^\s*frame=\s*\d+') {
                # 逐帧进度只在最后保留一条，避免日志被 \r 刷屏
                $lastFrame = $trimmed.Trim()
                continue
            }
            if ($trimmed.Trim().Length -eq 0) {
                if (-not $lastBlank -and $kept.Count -gt 0) { $kept.Add(''); $lastBlank = $true }
                continue
            }
            $kept.Add($trimmed)
            $lastBlank = $false
        }
        if ($lastFrame) { $kept.Add($lastFrame) }
        Write-Log "  [ffmpeg 报告] $($report.Name)（原始 $($lines.Count) 行，保留 $($kept.Count) 行，中间进度已省略）"
        foreach ($line in $kept) {
            Write-Log "      $line"
        }
    }
    catch {
        Write-Log "  [ffmpeg 报告] 读取失败: $($_.Exception.Message)"
    }
}

# 执行外部命令；返回退出码。DryRun 时只打印不执行。
# -CaptureFfmpegReport 仅给 ffmpeg 烧录用：额外写一份 ffmpeg-*.log 报告，
# 命令结束后再追加到主日志；控制台的 stderr 实时输出保持不变。
function Invoke-External {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$CaptureFfmpegReport
    )
    $oldFFReport = $env:FFREPORT
    if ($CaptureFfmpegReport -and -not $DryRun) {
        # -report 会把报告级别强制拉到 debug（Log level: 48），-loglevel 改不动它；
        # 只有 FFREPORT=level=32 能把报告降到 info，保留 Input/Output/Stream mapping/
        # libass/错误，同时去掉 nal_unit_type 等 debug 行。
        $env:FFREPORT = 'level=32'
        $Arguments = @('-report') + $Arguments
    }
    $cmdLine = Format-Argv -Exe $Exe -Arguments $Arguments
    if ($DryRun) {
        Write-Host ('   [DryRun] ' + $cmdLine) -ForegroundColor DarkCyan
        return 0
    }
    Write-Log "  [命令] $cmdLine"
    Write-Log "  [工作目录] $WorkingDirectory"
    # 记录运行前已存在的报告文件，稍后只读取本次新生成的那份
    $beforeReports = @()
    if ($CaptureFfmpegReport) {
        $beforeReports = @(
            Get-ChildItem -LiteralPath $WorkingDirectory -Filter 'ffmpeg-*.log' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name }
        )
    }
    Push-Location -LiteralPath $WorkingDirectory
    try {
        # 子进程 stdout 必须经 Out-Host 直接打到控制台。
        # 若写成 `& $Exe @Arguments`，子进程的 stdout 会被当作本函数的“返回值”，
        # 和退出码一起返回（$code 变成数组），退出码判断随即失效。
        # 这里在 Out-Host 之前逐行 tee 进日志；不要改成 2>&1：
        # Windows PowerShell 5.1 下原生程序的 stderr 并进管道会生成 NativeCommandError，
        # 配合 $ErrorActionPreference='Stop' 会直接中断脚本（见 AGENTS.md 6.6）。
        & $Exe @Arguments | ForEach-Object {
            Write-Log "    $_"
            $_
        } | Out-Host
        $code = $LASTEXITCODE
        Write-Log "  [退出码] $code"
        if ($CaptureFfmpegReport) {
            Write-FfmpegReport -WorkingDirectory $WorkingDirectory -BeforeFiles $beforeReports
        }
        return $code
    }
    finally {
        if ($CaptureFfmpegReport -and -not $DryRun) {
            # 只在本进程内临时设置，跑完恢复，避免影响用户自己的 ffmpeg 调用
            if ($null -eq $oldFFReport) {
                Remove-Item Env:FFREPORT -ErrorAction SilentlyContinue
            }
            else {
                $env:FFREPORT = $oldFFReport
            }
        }
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

# 从文件名/目录名/ffprobe tags 这类文本里找平台特征。
# 返回 douyin / bilibili / xiaohongshu，找不到返回 $null。
function Get-PlatformHint {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.ToLowerInvariant()

    # B站录播姬的固定命名：录制-<roomid>-...
    if ($t -match 'bilibili|b23\.tv|b23|hdslb|b站|录制-\d+-') { return 'bilibili' }
    # 抖音 DanmakuRender / 中文日期命名：2026年10月21日21点48分
    if ($t -match 'douyin|抖音|iesdouyin|\d{4}年\d{1,2}月\d{1,2}日\d{1,2}点\d{1,2}分') { return 'douyin' }
    # 小红书录制端命名：<标题>_2026-11-09_20-39-47；metadata: source=xhslive / X-Xhs-*
    if ($t -match 'xiaohongshu|小红书|xhslive|x-xhs|_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}') { return 'xiaohongshu' }
    return $null
}

# 读 ffprobe 的 format_tags / stream_tags，拼成文本供平台识别。
function Get-MediaTagText {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $out = & $FFprobe -v error -show_entries format_tags:stream_tags -of default=noprint_wrappers=1 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return '' }
    return (($out | ForEach-Object { $_.ToString() }) -join "`n")
}

# 判断录播来源（决定成品文件名前缀）
function Resolve-Platform {
    param(
        [string]$AssPath,
        [string]$XmlPath,
        [string]$VideoPath,
        [string]$FFprobe,
        [string]$Override   # auto / douyin / bilibili / xiaohongshu / none
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

    # 没有弹幕文件：先看视频文件名与所在目录名（录播软件的命名规律），
    # 再看 ffprobe metadata（小红书会带 source=xhslive / X-Xhs-*）。
    $hintText = ''
    if ($VideoPath) {
        $hintText = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath) + "`n" +
            (Split-Path -Leaf (Split-Path -Parent $VideoPath))
    }
    $hint = Get-PlatformHint -Text $hintText
    if ($hint) {
        return @{ Key = $hint; Reason = '视频文件名/目录名匹配平台特征' }
    }

    $tagText = Get-MediaTagText -FFprobe $FFprobe -Path $VideoPath
    $hint = Get-PlatformHint -Text $tagText
    if ($hint) {
        return @{ Key = $hint; Reason = '视频 metadata 匹配平台特征' }
    }

    # 三种来源里只有小红书目前不提供弹幕；无弹幕且无其他平台特征时按小红书处理。
    return @{ Key = 'xiaohongshu'; Reason = '无同名弹幕且文件名/目录/metadata 无其他平台特征，按小红书处理' }
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

# 逐包扫描 DTS，返回整条流的时间轴跨度（最大 DTS - 最小 DTS）。
# 容器没写时长时用它兜底：FLV 的 duration 来自 onMetaData，录制端没写时
# ffprobe 直接报 0.000000（不是 N/A），而 DTS 跨度就是播放器看到的时长。
# 比「视频包数 / 帧率」可靠：VFR 或时间戳空洞丢帧时后者会低估
# （实测某 47 分钟素材只算出 41.9 分钟）。
# 需要读完整个文件（实测 552 MB 约 0.7s），只在兜底时调用。
function Get-MediaSpanSeconds {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe) { return 0.0 }
    $out = & $FFprobe -v error -show_entries packet=dts_time -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0.0 }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $min = [double]::MaxValue
    $max = [double]::MinValue
    foreach ($line in $out) {
        $text = $line.ToString().Trim()
        if (-not $text -or $text -eq 'N/A') { continue }
        $d = 0.0
        if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) { continue }
        if ($d -lt $min) { $min = $d }
        if ($d -gt $max) { $max = $d }
    }
    if ($max -le $min) { return 0.0 }
    return [math]::Round($max - $min, 1)
}

# 视频包数 / 帧率。只在容器时长和 DTS 跨度都拿不到时才用它。
function Get-PacketBasedDuration {
    param([string]$FFprobe, [string]$Path, [double]$Fps)
    if (-not $FFprobe -or $Fps -le 0) { return 0.0 }
    $out = & $FFprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0.0 }
    $packets = 0
    if (-not [int]::TryParse((($out | Select-Object -First 1).ToString().Trim()), [ref]$packets)) { return 0.0 }
    if ($packets -le 0) { return 0.0 }
    return [math]::Round($packets / $Fps, 1)
}

# 预估专用时长：FLV 的时间戳空洞/倒流会把 format.duration 撑得很大
# （实测某 36 分钟素材报 2:37:03），而没写 onMetaData duration 的 FLV 会报 0。
# 正常文件仍用容器时长；撑大时用包数推算；报 0 时先按 DTS 跨度、再按包数推算。
# 只在启动预估时调用；主流程的画布采样仍用 Get-VideoDuration。
function Get-EffectiveVideoDuration {
    param([string]$FFprobe, [string]$Path)
    $duration = Get-VideoDuration -FFprobe $FFprobe -Path $Path
    $fps = Get-VideoFrameRate -FFprobe $FFprobe -Path $Path

    if ($duration -le 0) {
        $span = Get-MediaSpanSeconds -FFprobe $FFprobe -Path $Path
        if ($span -gt 0) { return $span }
        return Get-PacketBasedDuration -FFprobe $FFprobe -Path $Path -Fps $fps
    }

    if ($fps -le 0) { return $duration }
    $packetDuration = Get-PacketBasedDuration -FFprobe $FFprobe -Path $Path -Fps $fps
    if ($packetDuration -le 0) { return $duration }
    if ($duration -gt $packetDuration * 2.0) { return $packetDuration }
    return $duration
}

# 读视频的「标称帧率」，用于把时间戳塌陷/带空洞的源补成恒定帧率（CFR）。
# 优先 avg_frame_rate，其次 r_frame_rate；两者都可能是伪值（例如 1000/1），
# 超出 1..120 就不采信，返回 0 让调用方退回「只重编音频、不强制 CFR」。
function Get-VideoFrameRate {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe) { return 0.0 }
    $out = & $FFprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate -of default=nw=1 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0.0 }

    $avg = 0.0
    $r = 0.0
    foreach ($line in $out) {
        $text = $line.ToString().Trim()
        if ($text -match '^avg_frame_rate=(\d+)/(\d+)$') {
            $den = [double]$Matches[2]
            if ($den -gt 0) { $avg = [double]$Matches[1] / $den }
        }
        elseif ($text -match '^r_frame_rate=(\d+)/(\d+)$') {
            $den = [double]$Matches[2]
            if ($den -gt 0) { $r = [double]$Matches[1] / $den }
        }
    }
    foreach ($fps in @($avg, $r)) {
        if ($fps -ge 1.0 -and $fps -le 120.0) { return $fps }
    }
    return 0.0
}

# 有效帧率：优先用 stream 里的标称帧率；有些 TS 录制端会写成 r_frame_rate=2000/1、
# avg_frame_rate=0/0（实测），这时退回「视频包数 / 容器时长」。
# 只在常规字段不可用时才扫描全文件，正常 FLV 不会多花时间。
function Get-EffectiveFrameRate {
    param([string]$FFprobe, [string]$Path)
    $fps = Get-VideoFrameRate -FFprobe $FFprobe -Path $Path
    if ($fps -ge 1.0) { return $fps }
    if (-not $FFprobe) { return 0.0 }

    $duration = Get-VideoDuration -FFprobe $FFprobe -Path $Path
    if ($duration -le 0) { return 0.0 }
    $out = & $FFprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0.0 }
    $packets = 0
    $text = (($out | Select-Object -First 1).ToString().Trim() -split ',')[0].Trim()
    if (-not [int]::TryParse($text, [ref]$packets)) { return 0.0 }
    if ($packets -le 0) { return 0.0 }

    $avg = $packets / $duration
    if ($avg -ge 1.0 -and $avg -le 120.0) { return [math]::Round($avg, 3) }
    return 0.0
}

# 读首路视频的编码名（h264 / hevc / mpeg2video ...）。
# 仅消音转封装默认 -c:v copy，但 MP4 只适合 h264/hevc；其他编码直接拷会因为
# 容器不支持而失败，需要退回重编码。探不到时返回空串，调用方保持原来的 copy 行为。
function Get-VideoCodec {
    param([string]$FFprobe, [string]$Path)
    if (-not $FFprobe) { return '' }
    $out = & $FFprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return '' }
    # 某些 ffprobe 版本会在 csv 输出末尾多一个逗号，先按逗号取第一段
    $name = (($out | Select-Object -First 1).ToString().Trim() -split ',')[0].Trim()
    return $name.ToLowerInvariant()
}

# 成品时间戳自检：逐包比较相邻 DTS，检查「重复/倒退」与「过大间隔」。
# 平台（B站等）会拒收带时间戳跳变的文件，所以出片后立刻验证一次；
# 自检失败只告警并记入异常汇总，不删除已生成的成品。
function Test-MediaTimestamps {
    param(
        [string]$FFprobe,
        [string]$Path,
        [double]$MaxGap = 1.0
    )
    $result = @{ Ok = $true; Issues = @() }
    if (-not $FFprobe -or -not (Test-Path -LiteralPath $Path)) { return $result }

    $out = & $FFprobe -v error -show_entries packet=stream_index,dts_time -of csv=p=0 -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $result }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $prev = @{}
    $back = @{}
    $gap = @{}
    foreach ($line in $out) {
        $parts = $line.ToString().Trim() -split ','
        if ($parts.Count -lt 2) { continue }
        $idx = 0
        if (-not [int]::TryParse($parts[0], [ref]$idx)) { continue }
        $dts = 0.0
        try { $dts = [double]::Parse($parts[1], $inv) } catch { continue }

        if ($prev.ContainsKey($idx)) {
            $delta = $dts - $prev[$idx]
            if ($delta -le 0) {
                $back[$idx] = 1 + $(if ($back.ContainsKey($idx)) { $back[$idx] } else { 0 })
            }
            elseif (-not $gap.ContainsKey($idx) -or $delta -gt $gap[$idx]) {
                $gap[$idx] = $delta
            }
        }
        $prev[$idx] = $dts
    }

    foreach ($idx in @($prev.Keys)) {
        $b = if ($back.ContainsKey($idx)) { $back[$idx] } else { 0 }
        $g = if ($gap.ContainsKey($idx)) { $gap[$idx] } else { 0 }
        if ($b -gt 0 -or $g -gt $MaxGap) {
            $result.Ok = $false
            $result.Issues += "流 #${idx}: DTS 重复/倒退 ${b} 处，最大间隔 $([math]::Round($g, 3))s"
        }
    }
    return $result
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
    # 容器没写时长时（FLV 缺 onMetaData duration）采样点会全被跳过，
    # 只剩容器声明尺寸可选；用 DTS 跨度兜底，保证中途换分辨率的检查不被跳过。
    if ($dur -le 0) { $dur = Get-MediaSpanSeconds -FFprobe $FFprobe -Path $Path }
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

# 日志默认落在脚本所在目录的 logs\ 下（-LogDir 可改到别处）
if (-not $LogDir) { $LogDir = Join-Path $scriptDir 'logs' }

# 在打印启动信息之前初始化日志：后面的所有 Write-Host 都会自动入日志
Initialize-Log -LogDirectory $LogDir -Prefix '一键拆弹'
if ($script:LogWriter) {
    # 记录本次命令行参数（-DryRun 时不会走到这里）
    $paramParts = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $paramParts += "-$key" }
        }
        elseif ($value -is [bool]) {
            if ($value) { $paramParts += "-$key" }
        }
        else {
            $paramParts += "-$key `"$value`""
        }
    }
    Write-Log ("参数: " + ($paramParts -join ' '))
    Write-Log "目录: $Directory"
}

$beepScript = Join-Path $scriptDir 'beep_filter.py'
if (-not (Test-Path -LiteralPath $beepScript)) { throw "找不到 beep_filter.py: $beepScript" }

Write-Host ''
Write-Host '===== 一键拆弹 =====' -ForegroundColor Magenta
Write-Host "  目录     : $Directory"
Write-Host "  模型     : $ModelSize$(if ($modelAutoFast) { '（DryRun 预览默认 tiny；正式运行默认 large，可用 -ModelSize 指定）' })"
Write-Host "  消音     : $(if ($SkipMute) { '跳过' } else { '执行' })"
Write-Host "  弹幕烧录 : $(if ($SkipDanmaku) { '跳过' } else { '有弹幕则烧录，无则只消音' })"
Write-Host "  仅消音文件: $(if ($KeepMuted) { '保留' } else { '不保留（默认）' })"
Write-Host "  成品封装 : $Container"
Write-Host "  来源判断 : $Platform"
if ($ratioCheckOn) {
    Write-Host "  宽高比校验: 期望 $ExpectedRatio（有异常会在最后汇总提示；-ExpectedRatio none 可关闭）"
}
if ($DryRun) { Write-Host '  模式     : DryRun（仅预览命令，不改动任何文件）' -ForegroundColor Yellow }

# ffmpeg/ffprobe 始终需要：烧弹幕要编码，仅消音也要转封装 MP4
if (-not $FFmpegPath) {
    $ffCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffCmd) { throw 'PATH 中找不到 ffmpeg，请用 -FFmpegPath 指定。' }
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
# ffprobe：读画布/帧率/时间戳；烧 B站 xml 时还要拿它当 ASS 的 PlayRes
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
    Write-Warn '找不到 ffprobe：无法读取视频分辨率/时间戳，将退回默认画布并跳过时间戳修复'
}
if ($StyleFrom) {
    Write-Host "  字体样式 : 指定 $(Split-Path -Leaf $StyleFrom)"
}
if ($Lanes -gt 0) { Write-Host "  车道数   : $Lanes（覆盖默认）" }
if ($FontSize -gt 0) { Write-Host "  字号     : $FontSize px（覆盖默认）" }
if ($ScrollDuration -gt 0) { Write-Host "  滚动时长 : $ScrollDuration 秒（覆盖默认）" }

$vArgs = $EncoderArgs[$VideoEncoder] + @("-$(if ($VideoEncoder -eq 'nvenc') { 'cq' } else { 'crf' })", "$Quality")
$containerArgs = @()
# mp4/mov 加 faststart，把索引移到文件头部，便于上传后边下边播；mkv 不支持此选项
if ($Container -eq 'mp4' -or $Container -eq 'mov') {
    $containerArgs = @('-movflags', '+faststart')
}

# ---------- 收集待处理文件 ----------
# 只排除本流程/beep_filter 产出的文件，避免二次运行时把成品又当成新素材。
# 按「主文件名后缀」判断而不是完整文件名的后缀，这样与封装格式无关：
#   X_消音版.flv / X_消音版.ts / X_消音版_弹幕版.mp4 / X_消音版_手动修改.flv
# 都能被排除；而名字中间恰好含这些字样的原始素材（如 xxx_消音版原片.flv）仍会正常处理。
$producedStemSuffixes = @($MUTED_TAG, $DANMAKU_TAG, '_手动修改')
# 变量名沿用 $flvs / $flv（历史原因），实际包含 $VideoExtensions 里的所有容器：
# 目前是 .flv 与 .ts，两者走完全相同的流程。
$flvs = @(
    Get-ChildItem -LiteralPath $Directory -File |
        Where-Object {
            if ($VideoExtensions -notcontains $_.Extension.ToLowerInvariant()) {
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
    Write-Warn "目录中没有可处理的视频文件（$($VideoExtensions -join ' / ')）: $Directory"
    Send-CompletionNotification -Title '一键拆弹：没有待处理文件' -Message "目录中没有可处理的视频文件（$($VideoExtensions -join ' / ')）：$Directory"
    Close-Log -ExitCode 0
    exit 0
}
Write-Host "  待处理   : $($flvs.Count) 个视频" -ForegroundColor Gray

# ---------- 本次处理计划 ----------
# 先判断每个文件会走哪条路径，供启动清单/耗时预估和主循环共用。
# 平台判断对无弹幕文件要读 ffprobe metadata，缓存后主循环不再重复调用。
$plans = New-Object System.Collections.ArrayList
$planByPath = @{}
foreach ($flv in $flvs) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($flv.Name)
    # 中间产物沿用源容器的扩展名：.flv → _消音版.flv，.ts → _消音版.ts。
    # beep_filter.py 默认也按输入后缀命名，ps1 仍会显式 -o 指定，避免依赖默认值。
    $srcExt = $flv.Extension
    if (-not $srcExt) { $srcExt = '.flv' }
    $mutedPlain = Join-Path $Directory "${stem}${MUTED_TAG}${srcExt}"
    $assPath = Join-Path $Directory "${stem}.ass"
    $xmlPath = Join-Path $Directory "${stem}.xml"
    try {
        $plat = Resolve-Platform -AssPath $assPath -XmlPath $xmlPath -VideoPath $flv.FullName -FFprobe $FFprobePath -Override $Platform
    }
    catch {
        $plat = @{ Key = 'none'; Reason = "平台判断失败：$($_.Exception.Message)" }
    }
    $prefix = $PlatformPrefix[$plat.Key]
    if ($null -eq $prefix) { $prefix = '' }

    # 中间产物（仅消音，扩展名跟随源容器；带平台前缀，-KeepMuted 时才保留）
    $mutedFinal = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}${srcExt}"
    # 无弹幕时的最终成品（仅消音 MP4；-Container 可改 mov/mkv）
    $mutedMp4 = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}.${Container}"
    $danmakuPath = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}${DANMAKU_TAG}.${Container}"

    $hasAss = Test-Path -LiteralPath $assPath
    $hasXml = Test-Path -LiteralPath $xmlPath
    # ass（抖音）可直接烧；xml（B站）要先转成 ASS，两者都能出弹幕成品。
    # 万一同名 ass 与 xml 同时存在，以 ass 为准（不再重复烧一遍 xml）。
    $willBurn = ($hasAss -or $hasXml) -and -not $SkipDanmaku
    $finalPath = if ($willBurn) { $danmakuPath } else { $mutedMp4 }
    $mode = if ($willBurn) { 'burn' } else { 'remux' }

    $existingMuted = Find-MutedFile -Paths @($mutedPlain, $mutedFinal)
    $missingMuted = $SkipMute -and -not $existingMuted
    $needMute = -not $SkipMute -and -not ($existingMuted -and -not $Force)
    $exists = (Test-Path -LiteralPath $finalPath) -and -not $Force
    $skipReason = ''
    if ($exists) { $skipReason = '已存在成品' }
    elseif ($missingMuted) { $skipReason = '缺少消音版' }

    $filePlan = [pscustomobject]@{
        Flv           = $flv
        Stem          = $stem
        SourceExt     = $srcExt
        Plat          = $plat
        Prefix        = $prefix
        MutedPlain    = $mutedPlain
        MutedFinal    = $mutedFinal
        MutedMp4      = $mutedMp4
        DanmakuPath   = $danmakuPath
        AssPath       = $assPath
        XmlPath       = $xmlPath
        HasAss        = $hasAss
        HasXml        = $hasXml
        WillBurn      = $willBurn
        FinalPath     = $finalPath
        ExistingMuted = $existingMuted
        NeedMute      = $needMute
        MissingMuted  = $missingMuted
        Mode          = $mode
        Exists        = $exists
        SkipReason    = $skipReason
        DurationSec   = 0.0
        SizeBytes     = [long]0
    }
    $planByPath[$flv.FullName] = $filePlan
    [void]$plans.Add($filePlan)
}

# 只给真正要处理的文件读时长/大小；已存在成品或缺少消音版的文件在清单里只标原因，
# 不再花时间跑 ffprobe 读时长。
foreach ($filePlan in $plans) {
    if ($filePlan.Exists -or $filePlan.MissingMuted) { continue }
    $filePlan.SizeBytes = [long]$filePlan.Flv.Length
    if ($FFprobePath) {
        try {
            $filePlan.DurationSec = Get-EffectiveVideoDuration -FFprobe $FFprobePath -Path $filePlan.Flv.FullName
        }
        catch {
            $filePlan.DurationSec = 0.0
        }
    }
}

# ---------- 耗时预估 ----------
# 统计文件不存在时从历史日志回填一次；之后只读 run_stats.jsonl。
# 预估只用于提示，任何失败都不影响主流程。
$script:StatsPath = Get-RunStatsPath -LogDirectory $LogDir
if (-not $NoEstimate) {
    $history = @(Initialize-RunStats -Path $script:StatsPath -LogDirectory $LogDir -WantedRuns ([math]::Max(5, $HistoryRuns)))
    $script:EtaResult = Get-RunEta -Plans @($plans) -History $history -HistoryRuns $HistoryRuns
    $basisText = Get-EtaBasisText -Eta $script:EtaResult
    Write-EstimateList -Plans @($plans) -Eta $script:EtaResult -BasisText $basisText
}
else {
    $script:EtaResult = $null
    Write-EstimateList -Plans @($plans) -Eta $null -BasisText '已通过 -NoEstimate 关闭预估；本次不读取/写入运行统计'
}

# DryRun 预览在清单后等一次回车；非交互式（计划任务/重定向）自动继续，-Yes 跳过
if ($DryRun -and -not $Yes -and -not $NoEstimate) {
    $interactive = $true
    try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
    if ($interactive) {
        Write-Host ''
        Write-Host '  按 Enter 继续预览，Ctrl+C 取消...' -ForegroundColor Yellow
        $null = Read-Host
    }
    else {
        Write-Host '  检测到非交互式输入，DryRun 不暂停' -ForegroundColor DarkGray
    }
}

# ---------- 主流程 ----------
$results = New-Object System.Collections.ArrayList
# 每文件计时记录，运行结束时汇总成一条 run_stats.jsonl 记录
$fileStats = New-Object System.Collections.ArrayList
# 异常清单：跑完全部视频后在命令行最底部汇总提示（兜底提醒）
$anomalies = New-Object System.Collections.ArrayList
$failed = 0
# 抖音样式 ASS 按「视频宽高比」缓存：同一目录里可能既有竖屏也有横屏的录播，
# 不能只认第一份。
$styleCache = @{}
$biliConverter = Join-Path $scriptDir $BiliConverterName
$censorScript = Join-Path $scriptDir $CensorScriptName
$fitScript = Join-Path $scriptDir $FitScriptName
# B站 xml 转换结果是否已提示过「缺少转换脚本」
$convMissingWarned = $false
# 审查脚本缺失是否已提示过
$censorMissingWarned = $false
# 画布适配脚本缺失是否已提示过
$fitMissingWarned = $false
# 同名但不同容器的源文件（X.flv / X.ts）会落到同一个成品名：成品名里不含源扩展名。
# 检测到冲突时只处理第一个，后来的显式跳过并记入异常汇总，避免汇总里出现假的
# 「已存在(跳过)」让人以为两个文件都处理过。
$seenSourceStems = @{}

foreach ($flv in $flvs) {
    # 计划在启动时已经算好（含平台判断），这里直接复用，避免重复 ffprobe metadata
    $filePlan = $planByPath[$flv.FullName]
    $fileStartedAt = Get-Date
    $muteStartedAt = $null
    $finishStartedAt = $null
    $muteSeconds = 0.0
    $burnSeconds = 0.0
    $remuxSeconds = 0.0
    $script:FileFailed = $false

    if ($seenSourceStems.ContainsKey($filePlan.Stem)) {
        $firstSource = $seenSourceStems[$filePlan.Stem]
        Write-Warn "同名源文件冲突：$($flv.Name) 与 $firstSource 会生成同一个成品名，本文件跳过"
        [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '同名冲突(跳过)'; Output = $filePlan.FinalPath; Extras = @() })
        [void]$anomalies.Add([pscustomobject]@{
                Kind   = '同名源文件冲突'
                File   = $flv.Name
                Detail = "与 $firstSource 主文件名相同，成品名相同；已跳过本文件，请只保留一个容器"
            })
        continue
    }
    $seenSourceStems[$filePlan.Stem] = $flv.Name

    try {
    $stem = $filePlan.Stem
    # 注意必须用 ${stem} 花括号：$stem_消音版 会被解析成变量名 stem_消音版

    $mutedPlain = $filePlan.MutedPlain
    $assPath = $filePlan.AssPath
    $xmlPath = $filePlan.XmlPath
    $plat = $filePlan.Plat
    $prefix = $filePlan.Prefix
    $mutedFinal = $filePlan.MutedFinal
    $mutedMp4 = $filePlan.MutedMp4
    $danmakuPath = $filePlan.DanmakuPath
    $hasAss = $filePlan.HasAss
    $hasXml = $filePlan.HasXml
    $willBurn = $filePlan.WillBurn

    Write-Step "[$($flv.Name)]"
    Write-Host "   来源判断 : $($plat.Key) → 前缀 '$prefix'（$($plat.Reason)）" -ForegroundColor DarkGray

    $finalPath = $filePlan.FinalPath

    # ---- 画布探测 + 异常检查 ----
    # 特意放在「成品已存在就跳过」之前：已经出过片的素材同样要参与异常检查，
    # 否则重跑一遍会在什么都没查的情况下报「未发现异常」，那就成了假安慰。
    # B站连麦时录播机一般会另起一个新文件，所以同一文件内比例是恒定的；这里投票取
    # 多数是为了兜住「万一同一文件内换了比例」——那种情况直接上 ass 滤镜会让 ffmpeg
    # 崩溃（实测 0xC0000005）并留下损坏的 mp4。
    # scale+pad 归一化的代价：正常视频是恒等变换（实测 PSNR=inf、耗时无差异）。
    # 直接量原始视频：beep_filter 的消音步骤对视频流一律 -c:v copy，
    # 消音版的分辨率/比例/编码必然与原始文件一致，不必等中间产物生成。
    $probeTarget = $flv.FullName
    $canvas = Get-OutputCanvas -FFprobe $FFprobePath -FFmpeg $FFmpegPath -Path $probeTarget -Override $OutputSize
    # 有效帧率：用于把时间戳塌陷/带空洞的源补成 CFR；常规字段不可用时
    # 会退回「视频包数 / 容器时长」（TS 录制端常写伪帧率）；探不到就只修音频
    $srcFps = Get-EffectiveFrameRate -FFprobe $FFprobePath -Path $probeTarget
    # 视频编码：仅消音转封装走 -c:v copy 时，用它判断 MP4 是否装得下
    $srcCodec = Get-VideoCodec -FFprobe $FFprobePath -Path $probeTarget
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
        $muteStartedAt = Get-Date
        $pyArgs = @($beepScript, $flv.FullName, '-o', $mutedPlain, '--model-size', $ModelSize, '--no-log')
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
        $muteSeconds = [math]::Max(0.0, ((Get-Date) - $muteStartedAt).TotalSeconds)
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

                # 抖音 ASS 的 PlayRes 不一定等于录播画布。比例不一致时，libass 对 x 坐标
                # 和字号的缩放比例不同，滚动弹幕 \move 的终点（负的文字宽度）会缩得不够，
                # 文字还剩大半就随事件结束消失。烧录前在临时副本上重排到视频画布，
                # 原 ASS 不动；比例一致时脚本自己会跳过。
                if ($canvas) {
                    if (-not (Test-Path -LiteralPath $fitScript)) {
                        Write-Err "找不到画布适配脚本 $(Split-Path -Leaf $fitScript)，无法保证滚动弹幕完整滑出画面"
                        if (-not $fitMissingWarned) {
                            Write-Warn "请确认 $FitScriptName 与本脚本放在同一目录：$scriptDir"
                            $fitMissingWarned = $true
                        }
                        $prepOk = $false
                    }
                    else {
                        $fitArgs = @(
                            $fitScript, $workAss,
                            '--width', "$($canvas.Width)",
                            '--height', "$($canvas.Height)"
                        )
                        $fitCode = Invoke-External -Exe $PythonPath -Arguments $fitArgs -WorkingDirectory $scriptDir
                        if ($fitCode -ne 0) {
                            Write-Err "弹幕画布适配失败（退出码 $fitCode），已中止烧录"
                            $prepOk = $false
                        }
                    }
                }
                else {
                    Write-Warn '读不到视频画布，跳过弹幕画布适配；若 ASS 与视频比例不一致，滚动弹幕可能提前消失'
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

            # ---- 弹幕正文审查：命中敏感数字关键词的整行弹幕直接抹除 ----
            # 两条来源都走这里：抖音 ass 是拷进来的，B站 xml 是刚转换出来的，
            # 统一在「要烧的那份 ASS」上做，实现只有一处，也不会漏掉任何一条路径。
            # 关键词以 beep_filter.py 的 TARGET_KEYWORDS（音频同源）为基础，
            # 由 danmaku_censor.py 再叠加画面侧的视觉变体（0.64/6.4 等组合、全角数字、
            # 陆肆/陆拾肆/6月4 这类汉字写法）。
            if ($prepOk) {
                if ($SkipCensor) {
                    Write-Skip '指定 -SkipCensor，跳过弹幕正文审查（仅调试用）'
                }
                elseif (-not (Test-Path -LiteralPath $censorScript)) {
                    Write-Err "找不到审查脚本 $(Split-Path -Leaf $censorScript)，为避免漏审已中止烧录"
                    if (-not $censorMissingWarned) {
                        Write-Warn "请确认 $CensorScriptName 与本脚本放在同一目录：$scriptDir"
                        $censorMissingWarned = $true
                    }
                    $prepOk = $false
                }
                else {
                    $censorArgs = @($censorScript, $workAss, '--preview', '3')
                    $censCode = Invoke-External -Exe $PythonPath -Arguments $censorArgs -WorkingDirectory $scriptDir
                    if ($censCode -ne 0) {
                        Write-Err "弹幕正文审查失败（退出码 $censCode），为避免漏审已中止烧录"
                        $prepOk = $false
                    }
                }
            }

            if ($prepOk) {
                $finishStartedAt = Get-Date
                Write-Host "   Step 2 烧录弹幕（$VideoEncoder → $Container）..." -ForegroundColor Gray
                # 归一化滤镜必须在 ass 之前：先锁定帧尺寸，再让 libass 按固定画布绘制
                $vfFull = if ($vfNorm) { "$vfNorm,ass=danmaku.ass" } else { 'ass=danmaku.ass' }
                $ffArgs = @(
                    '-hide_banner', '-nostdin', '-stats',
                    '-i', $mutedPath,
                    '-vf', $vfFull
                )
                if ($filePlan.SourceExt -eq '.ts') {
                    # TS 里可能带字幕/数据流，MP4 装不下；显式只映射首路视频与音频。
                    # FLV 路径保持原有默认映射，不改已有行为。
                    $ffArgs += @('-map', '0:v:0', '-map', '0:a:0?')
                }

                # 时间戳修复：源录播文件可能有录制空洞/时间戳倒流（分段拼接、推流中断），
                # 直接重封装会把跳变带进成品，平台会以「时间戳跳变」拒收。
                # 只有检测到异常时才按源标称帧率补成 CFR；正常文件保持原时间戳，
                # 不做多余的补帧/丢帧（B站 30fps、抖音 18fps 都按各自源帧率）。
                $needCfr = $false
                if ($srcFps -ge 1.0) {
                    # 正式运行时检查实际要烧的消音版；DryRun 还没生成它，退回查源文件
                    $tsProbe = if (-not $DryRun -and (Test-Path -LiteralPath $mutedPath)) { $mutedPath } else { $probeTarget }
                    $srcTs = Test-MediaTimestamps -FFprobe $FFprobePath -Path $tsProbe
                    $needCfr = -not $srcTs.Ok
                    if ($needCfr) {
                        Write-Warn "源时间戳异常（$($srcTs.Issues -join '；')），烧录时启用 CFR 修复"
                    }
                    else {
                        Write-Host '   时间戳   : 源时间戳正常，保持原帧率/时间戳' -ForegroundColor DarkGray
                    }
                }
                else {
                    Write-Warn '读不到标称帧率，视频保持原始时间戳（仅修复音频）'
                }

                if ($needCfr) {
                    $fpsText = $srcFps.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
                    $ffArgs += @('-fps_mode', 'cfr', '-r', $fpsText)
                }

                # 音频始终重编：即使视频时间戳正常，源音频也可能有重复 DTS；
                # aresample 按时间戳补静音 / 重采样，保证音频轨连续。
                $ffArgs += $vArgs + $containerArgs + @(
                    '-c:a', 'aac', '-b:a', '192k',
                    '-af', 'aresample=async=1:first_pts=0',
                    '-avoid_negative_ts', 'make_zero',
                    '-max_muxing_queue_size', '1024',
                    '-y', $danmakuPath
                )
                $code = Invoke-External -Exe $FFmpegPath -Arguments $ffArgs -WorkingDirectory $workDir -CaptureFfmpegReport
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

            # 出片后自检：平台会因为「时间戳跳变」拒收，不能等用户上传失败才发现。
            if (-not $DryRun) {
                $tsCheck = Test-MediaTimestamps -FFprobe $FFprobePath -Path $danmakuPath
                if (-not $tsCheck.Ok) {
                    $tsDetail = $tsCheck.Issues -join '；'
                    Write-Warn "成品时间戳仍有异常：$tsDetail"
                    [void]$anomalies.Add([pscustomobject]@{
                            Kind   = '成品时间戳异常'
                            File   = $flv.Name
                            Detail = "$tsDetail（上传前请先用 -Force 重跑，或手工检查源文件）"
                        })
                }
                else {
                    Write-Host '   时间戳自检: 音视频 DTS 单调、无异常跳变' -ForegroundColor DarkGray
                }
            }

            Write-Produced $danmakuPath
            $burnSeconds = [math]::Max(0.0, ((Get-Date) - $finishStartedAt).TotalSeconds)
            $finalPath = $danmakuPath

            # -KeepAss：把「最终烧录用的那份 ASS」留一份（与成品同名，便于检查/手工微调）。
            # 两条来源都留：B站 xml 是转换出来的，抖音 ass 是审查过的副本 ——
            # 留这个的意义就在于能核对「到底往画面里烧了什么」。
            if ($KeepAss) {
                $assOut = Join-Path $Directory "${prefix}${stem}${MUTED_TAG}${DANMAKU_TAG}.ass"
                if ($DryRun) {
                    Write-Host "   [DryRun] 将保留烧录用的 ASS $(Split-Path -Leaf $assOut)" -ForegroundColor DarkCyan
                }
                else {
                    Copy-Item -LiteralPath $workAss -Destination $assOut -Force
                    $assTag = if ($SkipCensor) { '' } else { '（已过正文审查）' }
                    Write-Host "   已保留烧录用的 ASS$assTag $(Split-Path -Leaf $assOut)" -ForegroundColor DarkGray
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
        # 不烧弹幕（小红书 / -SkipDanmaku）：消音版还要转封装成最终 MP4。
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
            Write-Skip "没有同名弹幕文件（.ass / .xml），跳过弹幕烧录，改为输出仅消音 MP4"
        }

        Write-Host "   Step 2 仅消音转封装（$Container）..." -ForegroundColor Gray
        $finishStartedAt = Get-Date

        # 时间戳异常时按源标称帧率补 CFR；正常文件只做视频流拷贝转封装。
        $needCfr = $false
        if ($srcFps -ge 1.0) {
            $tsProbe = if (-not $DryRun -and (Test-Path -LiteralPath $mutedPath)) { $mutedPath } else { $probeTarget }
            $srcTs = Test-MediaTimestamps -FFprobe $FFprobePath -Path $tsProbe
            $needCfr = -not $srcTs.Ok
            if ($needCfr) {
                Write-Warn "源时间戳异常（$($srcTs.Issues -join '；')），转封装时启用 CFR 修复"
            }
            else {
                Write-Host '   时间戳   : 源时间戳正常，视频流直接拷贝' -ForegroundColor DarkGray
            }
        }
        else {
            Write-Warn '读不到标称帧率，仅修复音频时间戳'
        }

        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('muted_' + [guid]::NewGuid().ToString('N'))
        try {
            if (-not $DryRun) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

            $ffArgs = @('-hide_banner', '-nostdin', '-stats', '-i', $mutedPath)
            if ($filePlan.SourceExt -eq '.ts') {
                # TS 里可能带字幕/数据流，MP4 装不下；显式只映射首路视频与音频。
                # FLV 路径保持原有默认映射，不改已有行为。
                $ffArgs += @('-map', '0:v:0', '-map', '0:a:0?')
            }

            # 只有画布真的换过、时间戳异常，或源视频编码不适合 MP4 时才重编码；
            # 正常文件保持 -c:v copy。
            $copyableCodecs = @('h264', 'hevc')
            $codecNeedsReencode = $srcCodec -and ($copyableCodecs -notcontains $srcCodec)
            $reencode = $needCfr -or ($canvas -and $canvas.Mixed) -or $codecNeedsReencode
            if ($codecNeedsReencode) {
                Write-Warn "源视频编码 $srcCodec 不适合直接封装 MP4，转封装时将重编码为 H.264"
            }
            if ($canvas -and $canvas.Mixed) {
                $ffArgs += @('-vf', $vfNorm)
            }
            if ($needCfr) {
                $fpsText = $srcFps.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
                $ffArgs += @('-fps_mode', 'cfr', '-r', $fpsText)
            }
            if ($reencode) {
                $ffArgs += $vArgs
            }
            else {
                $ffArgs += @('-c:v', 'copy')
                if ($srcCodec -eq 'hevc') {
                    # HEVC 默认 tag 是 hev1，部分平台/播放器只认 hvc1
                    $ffArgs += @('-tag:v', 'hvc1')
                }
            }

            # 音频始终重编：即使视频时间戳正常，源音频也可能有重复 DTS；
            # aresample 按时间戳补静音/重采样，保证音频轨连续。
            $ffArgs += $containerArgs + @(
                '-c:a', 'aac', '-b:a', '192k',
                '-af', 'aresample=async=1:first_pts=0',
                '-avoid_negative_ts', 'make_zero',
                '-max_muxing_queue_size', '1024',
                '-y', $mutedMp4
            )
            $code = Invoke-External -Exe $FFmpegPath -Arguments $ffArgs -WorkingDirectory $workDir -CaptureFfmpegReport

            $convOk = ($code -eq 0)
            if (-not $DryRun -and -not (Test-Path -LiteralPath $mutedMp4)) { $convOk = $false }
            if (-not $convOk) {
                Write-Err "仅消音转封装失败（退出码 $code）"
                $failed++
                [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = '转封装失败'; Output = $mutedMp4; Extras = @() })
                continue
            }

            # 出片后自检：平台会因为「时间戳跳变」拒收，不能等上传失败才发现。
            if (-not $DryRun) {
                $tsCheck = Test-MediaTimestamps -FFprobe $FFprobePath -Path $mutedMp4
                if (-not $tsCheck.Ok) {
                    $tsDetail = $tsCheck.Issues -join '；'
                    Write-Warn "成品时间戳仍有异常：$tsDetail"
                    [void]$anomalies.Add([pscustomobject]@{
                            Kind   = '成品时间戳异常'
                            File   = $flv.Name
                            Detail = "$tsDetail（上传前请先用 -Force 重跑，或手工检查源文件）"
                        })
                }
                else {
                    Write-Host '   时间戳自检: 音视频 DTS 单调、无异常跳变' -ForegroundColor DarkGray
                }
            }

            Write-Produced $mutedMp4
            $remuxSeconds = [math]::Max(0.0, ((Get-Date) - $finishStartedAt).TotalSeconds)

            # 中间产物的去留
            if ($KeepMuted) {
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

            $finalPath = $mutedMp4
            $status = '仅消音'
        }
        finally {
            if (-not $DryRun -and (Test-Path -LiteralPath $workDir)) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    [void]$results.Add([pscustomobject]@{ File = $flv.Name; Status = $status; Output = $finalPath; Extras = $extras })
        }
        finally {
            $fileTotal = [math]::Max(0.0, ((Get-Date) - $fileStartedAt).TotalSeconds)
            # 失败/提前 continue 时也要有阶段耗时：用当前时刻兜底
            if ($muteStartedAt -and $muteSeconds -le 0) {
                $muteSeconds = [math]::Max(0.0, ((Get-Date) - $muteStartedAt).TotalSeconds)
            }
            if ($finishStartedAt -and ($burnSeconds + $remuxSeconds) -le 0) {
                $finishElapsed = [math]::Max(0.0, ((Get-Date) - $finishStartedAt).TotalSeconds)
                if ($filePlan.Mode -eq 'burn') { $burnSeconds = $finishElapsed }
                else { $remuxSeconds = $finishElapsed }
            }
            $probeStart = if ($muteStartedAt) { $muteStartedAt } elseif ($finishStartedAt) { $finishStartedAt } else { $null }
            $probeSeconds = if ($probeStart) { [math]::Max(0.0, ($probeStart - $fileStartedAt).TotalSeconds) } else { 0.0 }
            $stageTotal = $muteSeconds + $burnSeconds + $remuxSeconds
            # 成品已存在/跳过的文件不产生样本；失败和实际跑过阶段的文件都留记录
            if ($stageTotal -gt 0 -or $script:FileFailed) {
                [void]$fileStats.Add([pscustomobject]@{
                        Name        = $filePlan.Flv.Name
                        DurationSec = [double]$filePlan.DurationSec
                        SizeBytes   = [long]$filePlan.SizeBytes
                        MuteSec     = [math]::Round($muteSeconds, 1)
                        BurnSec     = [math]::Round($burnSeconds, 1)
                        RemuxSec    = [math]::Round($remuxSeconds, 1)
                        ProbeSec    = [math]::Round($probeSeconds, 1)
                        TotalSec    = [math]::Round($fileTotal, 1)
                        Mode        = [string]$filePlan.Mode
                        Failed      = [bool]$script:FileFailed
                    })
            }
        }
    }

# ---------- 汇总 ----------
Write-Host ''
Write-Host '===== 处理汇总 =====' -ForegroundColor Magenta
foreach ($r in $results) {
    $color = switch -Wildcard ($r.Status) { '*失败*' { 'Red' } '缺少*' { 'Red' } '仅消音' { 'Yellow' } '*冲突*' { 'Yellow' } '已存在*' { 'DarkGray' } default { 'Green' } }
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

$elapsed = if ($script:RunStarted) { (Get-Date) - $script:RunStarted } else { [TimeSpan]::Zero }
$elapsedText = "$([math]::Floor($elapsed.TotalMinutes)) 分 $($elapsed.Seconds) 秒"

# 运行结束写一条 live 统计，供下次启动预估使用；失败只警告，不影响退出码
if (-not $DryRun -and -not $NoEstimate -and $fileStats.Count -gt 0) {
    $statsPath = if ($script:StatsPath) { $script:StatsPath } else { Get-RunStatsPath -LogDirectory $LogDir }
    $estimateSeconds = if ($script:EtaResult) { [double]$script:EtaResult.TotalEtaSeconds } else { 0.0 }
    [void](Save-RunStats -Path $statsPath -Files @($fileStats) -Model $ModelSize -Encoder $VideoEncoder `
            -StartedAt $script:RunStarted -EndedAt (Get-Date) -EstimateSeconds $estimateSeconds)
}

# 预估/实际对比只在正式运行打印；DryRun 的耗时是模拟的，没有参考意义
if (-not $DryRun) {
    Write-EtaComparison -Eta $script:EtaResult -FileStats @($fileStats)
}

$notifyTitle = if ($failed -gt 0) { '一键拆弹：有失败项' } else { '一键拆弹：全部完成' }
$notifyMessage = "处理 $($results.Count) 个，失败 $failed 个，耗时 $elapsedText"
Send-CompletionNotification -Title $notifyTitle -Message $notifyMessage

if ($failed -gt 0) {
    Close-Log -ExitCode 1
    exit 1
}
Close-Log -ExitCode 0
exit 0
