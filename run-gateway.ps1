# 由排程工作呼叫：跑閘道器並把輸出（含時間戳）附加到 logs\gateway.log。
# 直接讓排程工作跑 python 沒辦法重導向輸出，所以包這一層。
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir "gateway.log"

# 讀 .env 的 HOST/PORT
$bindHost = "127.0.0.1"; $port = "8000"
if (Test-Path ".env") {
    $m = Select-String -Path ".env" -Pattern "^HOST=(.+)$"; if ($m) { $bindHost = $m.Matches.Groups[1].Value.Trim() }
    $m = Select-String -Path ".env" -Pattern "^PORT=(\d+)$"; if ($m) { $port = $m.Matches.Groups[1].Value.Trim() }
}

"===== gateway 啟動 $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") 綁定 ${bindHost}:$port =====" |
    Out-File -FilePath $log -Append -Encoding utf8

# *>> 把 native 程式的 stdout+stderr 一起附加進 log
& ".\.venv\Scripts\python.exe" -m uvicorn main:app --host $bindHost --port $port *>> $log
