# Start the tile-logs-sync receiver in the background (no console window).
#
#   powershell -ExecutionPolicy Bypass -File .\start_receiver.ps1
#
# Prints the shared token and the one-line bootstrap command for the VDI.
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [string]$Dest = "D:\Documents\ChatGPT\LNS_DSE\Tile_eval\logs",
    [string]$Config = (Join-Path $env:LOCALAPPDATA "tile-logs-sync\sync_config.json")
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$receiver = Join-Path $here "receiver.py"

function Find-Python {
    $candidates = @(
        "C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\pythonw.exe",
        "C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    foreach ($n in @("pythonw.exe", "python.exe")) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "python not found; install Python or adjust Find-Python"
}

$python = Find-Python
$busy = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) -ne $null
if ($busy) {
    Write-Host "port $Port already in use - receiver may already be running"
} else {
    Start-Process -FilePath $python -WindowStyle Hidden `
        -ArgumentList @("`"$receiver`"", "--port", "$Port", "--dest", "`"$Dest`"", "--config", "`"$Config`"")
    Start-Sleep -Seconds 2
    Write-Host "receiver started on port $Port"
}

if (-not (Test-Path $Config)) { throw "config not created yet: $Config" }
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "143.89.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $ip) { $ip = "<this-laptop-ip>" }

Write-Host ""
Write-Host "dest  : $($cfg.dest)"
Write-Host "token : $($cfg.token)"
Write-Host ""
Write-Host "On the VDI run:"
Write-Host ("  curl -fsS http://{0}:{1}/vdi_push_logs.sh -o ~/vdi_push_logs.sh && chmod +x ~/vdi_push_logs.sh" -f $ip, $Port)
