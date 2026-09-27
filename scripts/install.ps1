<#
.SYNOPSIS
  Spwrite installer for Windows (desktop) and Web.

.DESCRIPTION
  1. Verifies the Flutter SDK is installed.
  2. Enables the target platform in Flutter.
  3. Installs all build/runtime dependencies (flutter pub get, plus the
     SQLite WASM assets for web).
  4. Builds and launches the app -- immediately in this terminal, or detached
     in the background.

.PARAMETER Platform
  windows | web   (default: web)

.PARAMETER Mode
  now | background   (default: now)

.EXAMPLE
  .\scripts\install.ps1 web now
  .\scripts\install.ps1 windows background
#>
param(
  [ValidateSet('windows', 'web')]
  [string]$Platform = 'web',

  [ValidateSet('now', 'background')]
  [string]$Mode = 'now',

  [int]$WebPort = 8080
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }

# Resolve the project root (parent of this scripts\ directory).
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# --- 1. Flutter SDK check -------------------------------------------------
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error "Flutter SDK not found on PATH. Install it from https://docs.flutter.dev/get-started/install/windows then re-run this script."
  exit 1
}
Write-Step ("Flutter found: " + (flutter --version | Select-Object -First 1))

# --- 2. Enable the target platform ---------------------------------------
switch ($Platform) {
  'windows' { flutter config --enable-windows-desktop | Out-Null }
  'web'     { flutter config --enable-web | Out-Null }
}
Write-Step "Platform enabled: $Platform"

# --- 3. Install dependencies ---------------------------------------------
Write-Step "Installing Dart/Flutter package dependencies..."
flutter pub get

if ($Platform -eq 'web') {
  Write-Step "Setting up SQLite WASM assets for web..."
  try { dart run sqflite_common_ffi_web:setup }
  catch { Write-Warn "sqflite web setup reported an error; existing web\ assets will be used." }
}

# --- 4. Build ------------------------------------------------------------
Write-Step "Building the app for $Platform (first run can take a few minutes)..."
switch ($Platform) {
  'windows' { flutter build windows }
  'web'     { flutter build web }
}
Write-Step "Build complete."

# Point the user at the finished, standalone artifact.
switch ($Platform) {
  'windows' {
    $exe = Get-ChildItem -Path 'build\windows\x64\runner\Release' -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
      Write-Step "Your app is ready: $($exe.FullName)"
      Write-Step "Double-click the .exe, or copy the whole 'Release' folder to your Desktop."
    }
  }
  'web' {
    if (Test-Path 'build\web') { Write-Step "Your hostable web bundle is ready: $ProjectRoot\build\web" }
  }
}

# --- 5. Launch -----------------------------------------------------------
$runArgs = switch ($Platform) {
  'web'     { @('run', '-d', 'chrome', '--web-port', "$WebPort") }
  'windows' { @('run', '-d', 'windows') }
}

if ($Mode -eq 'background') {
  $logFile = Join-Path $ProjectRoot "spwrite-$Platform.log"
  Write-Step "Launching $Platform in the background. Logs: $logFile"
  $proc = Start-Process -FilePath 'flutter' -ArgumentList $runArgs `
            -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
            -WindowStyle Hidden -PassThru
  $proc.Id | Out-File (Join-Path $ProjectRoot "spwrite-$Platform.pid")
  Write-Step "Started (PID $($proc.Id))."
  if ($Platform -eq 'web') { Write-Step "Once compiled, open http://localhost:$WebPort" }
}
else {
  Write-Step "Launching $Platform in this terminal (Ctrl+C to stop)..."
  if ($Platform -eq 'web') { Write-Step "Once compiled, open http://localhost:$WebPort" }
  & flutter @runArgs
}
