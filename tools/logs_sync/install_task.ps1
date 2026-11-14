# Register the receiver to start automatically at logon, then start it now.
#
#   powershell -ExecutionPolicy Bypass -File .\install_task.ps1
#   schtasks /delete /tn TileLogsSyncReceiver /f     <- to remove
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [string]$TaskName = "TileLogsSyncReceiver"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$receiver = Join-Path $here "receiver.py"
$config = Join-Path $env:LOCALAPPDATA "tile-logs-sync\sync_config.json"

function Find-Python {
    $preferred = "C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\pythonw.exe"
    if (Test-Path $preferred) { return $preferred }
    $cmd = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "python not found"
}

$python = Find-Python
$action = New-ScheduledTaskAction -Execute $python `
    -Argument "`"$receiver`" --port $Port --config `"$config`"" `
    -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "task '$TaskName' registered (starts at logon)"

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "task state: $state"
if (Test-Path $config) {
    $cfg = Get-Content $config -Raw | ConvertFrom-Json
    Write-Host "token: $($cfg.token)"
    Write-Host "dest : $($cfg.dest)"
}
