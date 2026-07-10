# 啟動 Gemma4 閘道器（本機）。對外請另開 Cloudflare Tunnel，見 README。
$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"   # Windows 主控台印中文不崩

Set-Location $PSScriptRoot

if (-not (Test-Path ".\.venv")) {
    Write-Host "建立虛擬環境 .venv ..." -ForegroundColor Cyan
    python -m venv .venv
}
& ".\.venv\Scripts\python.exe" -m pip install -q -r requirements.txt

if (-not (Test-Path ".\.env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "已從 .env.example 複製出 .env，請先填入 API_KEYS 再重跑。" -ForegroundColor Yellow
    exit 1
}

$port = (Select-String -Path ".env" -Pattern "^PORT=(\d+)").Matches.Groups[1].Value
if (-not $port) { $port = "8000" }
$bindHost = (Select-String -Path ".env" -Pattern "^HOST=(.+)").Matches.Groups[1].Value
if (-not $bindHost) { $bindHost = "127.0.0.1" }

Write-Host "閘道器啟動於 http://${bindHost}:$port" -ForegroundColor Green
& ".\.venv\Scripts\python.exe" -m uvicorn main:app --host $bindHost --port $port
