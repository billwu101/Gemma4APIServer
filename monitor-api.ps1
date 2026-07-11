# 每隔一段時間實際打一次 gemma4 API，確認「能通」且「有用到 GPU」。
# 每輪：送一個真的 chat 請求 → 同時取樣 nvidia-smi 抓 GPU 峰值 → 印一行彩色結果。
#
# 用法： .\monitor-api.ps1                 每 60 秒測公網 API（預設）
#        .\monitor-api.ps1 -IntervalSec 30 改成每 30 秒
#        .\monitor-api.ps1 -Local          改測本機 http://localhost:8000（不經 tunnel）
#        .\monitor-api.ps1 -LogFile mon.log 另存純文字紀錄
#
# 判定：HTTP 200 且回應含 choices/content = 通；GPU 峰值 >= 門檻 = 有吃 GPU。
# Ctrl+C 離開（不影響服務）。
param(
    [int]$IntervalSec = 60,
    [switch]$Local,
    [int]$GpuThreshold = 40,     # GPU 峰值 >= 此值(%) 視為有在推論
    [string]$LogFile
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$Host.UI.RawUI.WindowTitle = "Gemma4 API 監看（每 ${IntervalSec}s）"

# 從 .env 讀第一把金鑰（name:key）
$envLine = (Get-Content .env | Where-Object { $_ -match '^\s*API_KEYS\s*=' } | Select-Object -First 1)
if (-not $envLine) { Write-Host ".env 找不到 API_KEYS。" -ForegroundColor Red; exit 1 }
$firstPair = ($envLine -replace '^\s*API_KEYS\s*=', '').Split(',')[0].Trim()
$key = $firstPair.Split(':', 2)[1]
if (-not $key) { Write-Host "解析金鑰失敗：$firstPair" -ForegroundColor Red; exit 1 }

$base = if ($Local) { "http://localhost:8000" } else { "https://Gemma4API.myddns101ddnsking.uk" }
$url  = "$base/v1/chat/completions"
# 生成稍長內容，讓 GPU 負載持續 1~2 秒，取樣才抓得到尖峰（不然瞬間推論會漏測）
$body = '{"model":"gpt-4o","messages":[{"role":"user","content":"用約80字介紹深度學習"}],"max_tokens":160}'

Write-Host "監看目標： $url" -ForegroundColor Cyan
Write-Host "金鑰名稱： $($firstPair.Split(':',2)[0])   間隔： ${IntervalSec}s   GPU 門檻： ${GpuThreshold}%" -ForegroundColor Cyan
Write-Host "（Ctrl+C 離開，不影響服務）" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $ts = (Get-Date).ToString("MM-dd HH:mm:ss")

    # 送請求（背景 job），前景同時連續取樣 GPU 抓峰值
    $job = Start-Job -ScriptBlock {
        param($u, $k, $b)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & curl.exe -s -o - -w "`n%{http_code}" --max-time 60 $u `
            -H "Authorization: Bearer $k" -H "Content-Type: application/json" -d $b 2>&1
        $sw.Stop()
        [pscustomobject]@{ Raw = ($out -join "`n"); Ms = $sw.ElapsedMilliseconds }
    } -ArgumentList $url, $key, $body

    $peakUtil = 0; $peakPower = 0
    while ($job.State -eq 'Running') {
        $s = (& nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>$null)
        if ($s) {
            $parts = ($s -split "`n")[0].Split(',')
            $u = [int]([double]$parts[0].Trim()); $p = [double]$parts[1].Trim()
            if ($u -gt $peakUtil)  { $peakUtil  = $u }
            if ($p -gt $peakPower) { $peakPower = $p }
        }
        Start-Sleep -Milliseconds 150
    }
    $r = Receive-Job $job; Remove-Job $job

    # 解析結果
    $raw = [string]$r.Raw
    $code = if ($raw -match '(\d{3})\s*$') { $Matches[1] } else { "---" }
    $apiOk = ($code -eq "200") -and ($raw -match '"(choices|content)"')
    # GPU 判定：取樣峰值達門檻，或 ollama 回報模型跑在 GPU 上（雙保險，避免瞬間推論漏測）
    $onGpu = (& docker compose exec -T ollama ollama ps 2>$null | Out-String) -match 'GPU'
    $gpuOk = ($peakUtil -ge $GpuThreshold) -or $onGpu

    # 組狀態文字與顏色
    if ($apiOk -and $gpuOk)      { $status = "正常（通 + GPU）"; $color = "Green" }
    elseif ($apiOk -and -not $gpuOk) { $status = "通但模型不在 GPU（疑似掉到 CPU！）"; $color = "Yellow" }
    else                          { $status = "失敗（API 不通）"; $color = "Red" }

    $line = "[$ts] API code=$code $($r.Ms)ms  GPU峰值=$peakUtil%  ${peakPower}W  ->  $status"
    Write-Host $line -ForegroundColor $color
    if ($LogFile) { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }

    Start-Sleep -Seconds $IntervalSec
}
