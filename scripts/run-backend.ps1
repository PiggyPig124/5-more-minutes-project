param(
    [int]$Port = 8000,
    [string]$BindAddress = '127.0.0.1'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonExe = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw 'Create .venv and install backend/requirements.lock.txt first. See README.md.'
}
Push-Location (Join-Path $projectRoot 'backend')
try {
    & $pythonExe -m uvicorn app.main:app --host $BindAddress --port $Port
    if ($LASTEXITCODE -ne 0) { throw "Backend exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}
