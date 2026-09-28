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

.PARAMETER Deps
  When set, first installs the system prerequisites -- Flutter and the Visual
  Studio C++ build tools -- using winget (falling back to Chocolatey if
  present), then continues with the normal build + run. Each install asks for
  confirmation first. You may also pass the bare word 'deps' as an argument.

.PARAMETER AssumeYes
  Answer "yes" to every confirmation prompt (non-interactive installs).

.EXAMPLE
  .\scripts\install.ps1 web now
  .\scripts\install.ps1 windows background
  .\scripts\install.ps1 windows -Deps
  .\scripts\install.ps1 deps
#>
param(
  [ValidateSet('windows', 'web', 'deps')]
  [string]$Platform = 'web',

  [ValidateSet('now', 'background', 'deps')]
  [string]$Mode = 'now',

  [int]$WebPort = 8080,

  [switch]$Deps,

  [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'

# Accept the bare word 'deps' in either positional slot, then normalize the
# platform/mode back to their real defaults.
$WantDeps = [bool]$Deps
if ($Platform -eq 'deps') { $WantDeps = $true; $Platform = 'web' }
if ($Mode -eq 'deps')     { $WantDeps = $true; $Mode = 'now' }

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }

# Ask a yes/no question. Returns $true for yes. Honors -AssumeYes, and defaults
# to "no" when running non-interactively so an unattended run never blocks.
function Confirm-Step($msg) {
  if ($AssumeYes) { Write-Step "$msg -> yes (AssumeYes)"; return $true }
  if ([Environment]::UserInteractive -eq $false) {
    Write-Warn "$msg -> no (non-interactive; skipping)"; return $false
  }
  $reply = Read-Host "[?] $msg [y/N]"
  return @('y', 'Y', 'yes', 'YES') -contains $reply
}

# Windows dependency bootstrap: prefer winget (ships with modern Windows),
# fall back to Chocolatey when present. Installs Flutter and, for a desktop
# build, the Visual Studio C++ build tools.
function Invoke-Bootstrap {
  $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
  $haveChoco  = [bool](Get-Command choco  -ErrorAction SilentlyContinue)

  if (-not $haveWinget -and -not $haveChoco) {
    Write-Warn "Neither winget nor Chocolatey is available."
    Write-Warn "Install winget (App Installer) from the Microsoft Store, or Chocolatey from https://chocolatey.org/install, then re-run with -Deps."
    Write-Warn "Or install Flutter manually: https://docs.flutter.dev/get-started/install/windows"
    return
  }

  # Flutter.
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    if (Confirm-Step "Install Flutter now?") {
      if ($haveWinget) {
        Write-Step "Installing Flutter via winget..."
        winget install --id Google.Flutter -e --accept-source-agreements --accept-package-agreements
      } else {
        Write-Step "Installing Flutter via Chocolatey..."
        choco install flutter -y
      }
      Write-Warn "You may need to open a new terminal so 'flutter' is on your PATH, then re-run."
    }
  }

  # Visual Studio C++ build tools — required only for a Windows desktop build,
  # not for the web build.
  if ($Platform -eq 'windows') {
    if (Confirm-Step "Install the Visual Studio C++ build tools (large download)?") {
      if ($haveWinget) {
        Write-Step "Installing Visual Studio Build Tools with the C++ workload via winget..."
        winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements `
          --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
      } else {
        Write-Step "Installing Visual Studio Build Tools via Chocolatey..."
        choco install visualstudio2022buildtools -y --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
      }
    }
  }
}

# Resolve the project root (parent of this scripts\ directory).
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# --- 0. Dependency bootstrap (opt-in) ------------------------------------
if ($WantDeps) {
  Write-Step "Installing prerequisites (deps mode)..."
  Invoke-Bootstrap
}

# --- 1. Flutter SDK check -------------------------------------------------
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  # If the user did not ask for deps, offer the bootstrap now rather than just
  # failing, so a first-time user has a one-word path forward.
  if (-not $WantDeps -and (Confirm-Step "Flutter is not installed. Install prerequisites automatically now?")) {
    Invoke-Bootstrap
  }
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error "Flutter SDK not found on PATH. Install it automatically by re-running with -Deps (e.g. '.\scripts\install.ps1 $Platform -Deps'), or manually from https://docs.flutter.dev/get-started/install/windows then re-run. If you just installed it, open a new terminal so PATH updates."
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
