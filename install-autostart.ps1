# 把閘道器註冊成開機自動啟動的排程工作（需管理員權限）。
#
#   .\install-autostart.ps1              # 只註冊閘道器（Ollama 沿用 Startup 資料夾的 tray app）
#   .\install-autostart.ps1 -WithOllama  # 連 Ollama 也開機啟動（不需登入）
#   .\install-autostart.ps1 -Uninstall   # 移除本腳本註冊的工作
#
# 身分用 S4U（Service For User）：以目前使用者執行、開機即啟動、不需登入、不必存密碼。
# 不能用 SYSTEM —— Ollama 會去 systemprofile 找模型，看不到 %USERPROFILE%\.ollama\models。
[CmdletBinding()]
param(
    [switch]$WithOllama,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$GatewayTask = 'Gemma4 Gateway'
$OllamaTask  = 'Ollama Server'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "需要管理員權限。請以系統管理員身分開啟 PowerShell 再執行。"
}

if ($Uninstall) {
    foreach ($n in @($GatewayTask, $OllamaTask)) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false
            Write-Host "[ok] removed: $n" -ForegroundColor Green
        }
    }
    return
}

$Project = $PSScriptRoot
$Python  = Join-Path $Project '.venv\Scripts\python.exe'
$User    = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-Path $Python)) { throw "找不到 venv：$Python（先跑一次 .\start.ps1）" }

# 崩潰時每 1 分鐘重試、最多 3 次。ExecutionTimeLimit 0 = 不限時；
# 預設是 3 天，時間到工作會被系統直接砍掉。
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited

# 從 .env 讀 HOST/PORT，沒有就用預設
$envFile = Join-Path $Project '.env'
$bindHost = '127.0.0.1'; $port = '8000'
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^HOST=(.+)$'; if ($m) { $bindHost = $m.Matches.Groups[1].Value.Trim() }
    $m = Select-String -Path $envFile -Pattern '^PORT=(\d+)$'; if ($m) { $port = $m.Matches.Groups[1].Value.Trim() }
}

# 晚 20 秒起，讓 Ollama 先綁好 11434。非必要（httpx client 是 lazy 的），
# 只是減少開機初期打進來的請求吃到 502。
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT20S'

$action = New-ScheduledTaskAction -Execute $Python `
    -Argument "-m uvicorn main:app --host $bindHost --port $port" `
    -WorkingDirectory $Project   # 必須：.env / usage.db 都是相對路徑

Register-ScheduledTask -TaskName $GatewayTask -Force `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Gemma4 API 閘道器，開機啟動於 ${bindHost}:$port" | Out-Null
Write-Host "[ok] 已註冊: $GatewayTask -> ${bindHost}:$port" -ForegroundColor Green

if ($WithOllama) {
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollama) { $ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" }
    if (-not (Test-Path $ollama)) { throw "找不到 ollama.exe：$ollama" }

    Register-ScheduledTask -TaskName $OllamaTask -Force `
        -Action (New-ScheduledTaskAction -Execute $ollama -Argument 'serve') `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings `
        -Description 'Ollama 推論後端，開機啟動於 127.0.0.1:11434' | Out-Null
    Write-Host "[ok] 已註冊: $OllamaTask" -ForegroundColor Green
    Write-Warning "請把 Startup 資料夾的 Ollama.lnk 移走，否則登入時 tray app 會搶 11434 埠並 bind 失敗。"
}

Get-ScheduledTask | Where-Object { $_.TaskName -in @($GatewayTask, $OllamaTask) } |
    Select-Object TaskName, State | Format-Table -AutoSize
