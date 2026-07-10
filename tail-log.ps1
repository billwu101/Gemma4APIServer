# 即時觀察閘道器 log，依 HTTP 狀態碼與 log 等級上色。
# log 檔是純文字（顏色無法存進檔案），所以上色在此顯示端做。
$ErrorActionPreference = "SilentlyContinue"
$log = Join-Path $PSScriptRoot "logs\gateway.log"
$Host.UI.RawUI.WindowTitle = "Gemma4 Gateway log"

# 依一行內容決定顏色。存取紀錄看狀態碼，其餘看 log 等級。
function Get-LineColor([string]$line) {
    if ($line -match 'HTTP/[\d.]+"\s+(\d{3})') {
        switch ([int]$Matches[1]) {
            { $_ -ge 500 } { return "Red" }        # 5xx 伺服器/上游錯誤（502…）
            { $_ -ge 400 } { return "Yellow" }     # 4xx 用戶端錯誤（401/403/404…）
            { $_ -ge 300 } { return "Cyan" }       # 3xx 轉向
            default        { return "Green" }      # 2xx 成功
        }
    }
    if ($line -match '\|\s*ERROR\s*\|')   { return "Red" }
    if ($line -match '\|\s*WARNING\s*\|') { return "Yellow" }
    if ($line -match '^=====')            { return "Magenta" }   # 啟動橫幅
    if ($line -match '\|\s*INFO\s*\|')    { return "DarkGray" }
    return "Gray"
}

Write-Host "tail: $log  (Ctrl+C 離開，不影響 server)" -ForegroundColor Cyan
Write-Host "顏色： " -NoNewline
Write-Host "2xx" -ForegroundColor Green -NoNewline; Write-Host " / " -NoNewline
Write-Host "3xx" -ForegroundColor Cyan -NoNewline;  Write-Host " / " -NoNewline
Write-Host "4xx" -ForegroundColor Yellow -NoNewline; Write-Host " / " -NoNewline
Write-Host "5xx·ERROR" -ForegroundColor Red
while (-not (Test-Path $log)) { Write-Host "等待 log 產生..." -ForegroundColor DarkGray; Start-Sleep 1 }
Get-Content -Path $log -Wait -Tail 40 | ForEach-Object {
    Write-Host $_ -ForegroundColor (Get-LineColor $_)
}
