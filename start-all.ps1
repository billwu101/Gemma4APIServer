# 一鍵啟動全部 Docker 服務（ollama + gateway + cloudflared，一律重新 build），
# 然後即時顯示 API 後台的連線情況。
# 用法： .\start-all.ps1            build + 啟動，並在本視窗即時監看連線
#        .\start-all.ps1 -NoWatch  build + 啟動，但不進監看
#
# 監看畫面依 HTTP 狀態碼上色：2xx 綠 / 3xx 青 / 4xx 黃 / 5xx·錯誤 紅。
# 在監看畫面按 Ctrl+C = 離開監看並「自動關閉全部服務」（等同 stop-all.ps1）。
# 若只想啟動、不想按 Ctrl+C 就把服務關掉，改用 .\start-all.ps1 -NoWatch。
param(
    [switch]$NoWatch
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$Host.UI.RawUI.WindowTitle = "Gemma4 API - 連線監看"

# 1) 確認 Docker daemon 有在跑
Write-Host "檢查 Docker..." -ForegroundColor Cyan
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker 沒在跑。請先開 Docker Desktop。" -ForegroundColor Red
    exit 1
}

# 2) build 並啟動全部服務（一律 --build）
Write-Host "build 並啟動服務（ollama + gateway + cloudflared）..." -ForegroundColor Cyan
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { Write-Host "compose 啟動失敗。" -ForegroundColor Red; exit 1 }

# 3) 等 gateway 健康。讀 Docker 內建 healthcheck 狀態（在容器內跑，不受主機 proxy 影響）
Write-Host "等待 gateway 就緒..." -ForegroundColor DarkGray
for ($i = 0; $i -lt 30; $i++) {
    $h = (docker inspect -f "{{.State.Health.Status}}" gemma4-gateway 2>$null)
    if ($h -eq "healthy") { Write-Host "gateway 就緒。" -ForegroundColor Green; break }
    Start-Sleep 1
}
if ($h -ne "healthy") { Write-Host "gateway 尚未回報 healthy（可能仍在啟動，稍等再看下方狀態）。" -ForegroundColor Yellow }

# 4) 顯示容器狀態
Write-Host ""
docker compose ps
Write-Host ""
Write-Host "公網網址： https://Gemma4API.myddns101ddnsking.uk" -ForegroundColor Cyan
Write-Host "本機網址： http://localhost:8000" -ForegroundColor Cyan
Write-Host ""

if ($NoWatch) { Write-Host "服務已啟動（-NoWatch，不進監看）。" -ForegroundColor Green; exit 0 }

# 5) 即時監看 gateway 連線（uvicorn 存取紀錄），依狀態碼上色
function Get-LineColor([string]$line) {
    if ($line -match 'HTTP/[\d.]+"\s+(\d{3})') {
        switch ([int]$Matches[1]) {
            { $_ -ge 500 } { return "Red" }        # 5xx 伺服器/上游錯誤（502…）
            { $_ -ge 400 } { return "Yellow" }     # 4xx 用戶端錯誤（401/403/404…）
            { $_ -ge 300 } { return "Cyan" }       # 3xx 轉向
            default        { return "Green" }      # 2xx 成功
        }
    }
    if ($line -match 'ERROR|Traceback|Exception') { return "Red" }
    if ($line -match 'WARNING')                   { return "Yellow" }
    return "Gray"
}

Write-Host "===== 即時連線監看（Ctrl+C 離開並關閉全部服務）=====" -ForegroundColor Magenta
Write-Host "顏色： " -NoNewline
Write-Host "2xx" -ForegroundColor Green -NoNewline;  Write-Host " / " -NoNewline
Write-Host "3xx" -ForegroundColor Cyan -NoNewline;   Write-Host " / " -NoNewline
Write-Host "4xx" -ForegroundColor Yellow -NoNewline; Write-Host " / " -NoNewline
Write-Host "5xx·ERROR" -ForegroundColor Red
Write-Host ""

# 跟隨 gateway 容器 log；--tail 40 先帶出最近 40 行。
# 按 Ctrl+C 離開監看時，finally 會自動關閉全部服務（等同 stop-all.ps1）。
# 只濾掉「127.0.0.1 自己」的 healthcheck 探測（每 30 秒），其他來源的 /health 照常顯示。
try {
    docker compose logs -f --tail 40 gateway 2>&1 | ForEach-Object {
        if ($_ -match '127\.0\.0\.1:\d+ - "(GET|HEAD) /health ') { return }   # 跳過本機自我探測噪音
        Write-Host $_ -ForegroundColor (Get-LineColor $_)
    }
}
finally {
    Write-Host ""
    Write-Host "偵測到離開監看，關閉全部服務（保留模型與 usage.db）..." -ForegroundColor Yellow
    docker compose down
    Write-Host "已全部關閉。" -ForegroundColor Green
}
