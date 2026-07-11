# 在 Startup 資料夾放一個捷徑，讓每次登入自動開一個彩色 tail 視窗觀察 logs\gateway.log。
# 閘道器本身是開機 headless 啟動（S4U/session 0，沒有可見視窗）；這個視窗只是觀察用，
# 關掉不影響 server。不需要管理員權限。
#
#   .\install-tail-window.ps1            # 安裝（登入時自動開）
#   .\install-tail-window.ps1 -Uninstall # 移除捷徑
[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$startup  = [Environment]::GetFolderPath('Startup')
$lnkPath  = Join-Path $startup 'Gemma4 Gateway log.lnk'

if ($Uninstall) {
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "[ok] 已移除: $lnkPath" -ForegroundColor Green }
    else { Write-Host "[skip] 沒有這個捷徑" }
    return
}

# shell 用穩定的 WindowsApps pwsh alias（不帶版號，升級不失效），沒有就退回內建 5.1
$shell = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
if (-not (Test-Path $shell)) { $shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$tail = Join-Path $PSScriptRoot 'tail-log.ps1'
if (-not (Test-Path $tail)) { throw "找不到 tail-log.ps1：$tail" }

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
$lnk.TargetPath       = $shell
$lnk.Arguments        = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$tail`""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.WindowStyle      = 1          # 一般視窗
$lnk.Description      = 'Gemma4 Gateway log（登入時自動開，觀察用，關掉不影響 server）'
$lnk.Save()

Write-Host "[ok] 已安裝: $lnkPath" -ForegroundColor Green
Write-Host "     下次登入會自動開一個彩色 tail 視窗。" -ForegroundColor DarkGray
