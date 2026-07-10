# 即時觀察閘道器 log。開機時也可自動開一個視窗跑這個。
$ErrorActionPreference = "SilentlyContinue"
$log = Join-Path $PSScriptRoot "logs\gateway.log"
$Host.UI.RawUI.WindowTitle = "Gemma4 Gateway log"
Write-Host "tail: $log  (Ctrl+C 離開，不影響 server)" -ForegroundColor Cyan
while (-not (Test-Path $log)) { Write-Host "等待 log 產生..." -ForegroundColor DarkGray; Start-Sleep 1 }
Get-Content -Path $log -Wait -Tail 40
