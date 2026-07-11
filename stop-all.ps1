# 關閉全部 Docker 服務（ollama + gateway + cloudflared）。
# 用法： .\stop-all.ps1           停掉容器（模型與 usage.db 保留，下次啟動不必重拉）
#        .\stop-all.ps1 -Purge    連模型 volume 也刪掉（下次要重拉 18GB，慎用）
param(
    [switch]$Purge
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if ($Purge) {
    Write-Host "關閉服務並刪除模型 volume（下次啟動要重拉 gemma4:26b）..." -ForegroundColor Yellow
    docker compose down -v
} else {
    Write-Host "關閉服務（保留模型與 usage.db）..." -ForegroundColor Cyan
    docker compose down
}
if ($LASTEXITCODE -ne 0) { Write-Host "compose 關閉失敗。" -ForegroundColor Red; exit 1 }
Write-Host "已全部關閉。" -ForegroundColor Green
