param(
    [string]$ApiOrigin = 'http://10.0.2.2:8000',
    [string]$Device = '',
    [string]$FlutterSdk = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($FlutterSdk) {
    $flutterExe = Join-Path $FlutterSdk 'bin\flutter.bat'
} else {
    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Flutter was not found. Pass -FlutterSdk with the SDK directory.' }
    $flutterExe = $command.Source
}
Push-Location (Join-Path $projectRoot 'app')
try {
    $runArguments = @('run', "--dart-define=API_ORIGIN=$ApiOrigin")
    if ($Device) { $runArguments += @('-d', $Device) }
    & $flutterExe @runArguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}
