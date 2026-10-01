<#
.SYNOPSIS
  Spwrite installer for Windows (desktop) and Web.

.DESCRIPTION
  1. Checks for Flutter and everything Windows needs to build Spwrite, and
     (with your permission) installs whatever is missing.
  2. Enables the target platform in Flutter.
  3. Installs the app's packages (flutter pub get, plus the SQLite WASM
     assets for web).
  4. Builds and launches the app -- immediately in this terminal, or detached
     in the background.

  What gets installed (winget preferred, Chocolatey as a fallback):
    - Git
    - Flutter (official stable checkout in %USERPROFILE%\development\flutter,
      added to your user PATH)
    - For a Windows app: Visual Studio 2022 Build Tools with the
      "Desktop development with C++" workload (MSVC + Windows SDK)
    - For web (optional): Google Chrome (Microsoft Edge also works)
  It also checks Windows Developer Mode, which Flutter plugins need for
  symlinks, and offers to open the Settings page to turn it on.
  SQLite needs no install: it is bundled by the sqlite3_flutter_libs package.

.PARAMETER Platform
  windows | web   (default: web)

.PARAMETER Mode
  now | background   (default: now)

.PARAMETER Deps
  Install the prerequisites first, then continue with the normal build + run.
  Each install asks for confirmation first. The bare word 'deps' also works.
  Even without -Deps, the installer offers to install anything missing.

.PARAMETER Check
  Only report what is installed and what is missing, then exit. Changes
  nothing. The bare word 'check' also works.

.PARAMETER WebPort
  Port for the web version (default: 8080).

.PARAMETER AssumeYes
  Answer "yes" to every confirmation prompt (non-interactive installs).

.EXAMPLE
  .\scripts\install.ps1 web now
  .\scripts\install.ps1 windows background
  .\scripts\install.ps1 windows -Deps
  .\scripts\install.ps1 deps
  .\scripts\install.ps1 windows check
#>
param(
  [ValidateSet('windows', 'web', 'deps', 'check')]
  [string]$Platform = 'web',

  [ValidateSet('now', 'background', 'deps', 'check')]
  [string]$Mode = 'now',

  [int]$WebPort = 8080,

  [switch]$Deps,

  [switch]$Check,

  [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'

# Accept the bare words 'deps' / 'check' in either positional slot, then
# normalize the platform/mode back to their real defaults.
$WantDeps  = [bool]$Deps
$CheckOnly = [bool]$Check
if ($Platform -eq 'deps')  { $WantDeps = $true;  $Platform = 'web' }
if ($Platform -eq 'check') { $CheckOnly = $true; $Platform = 'web' }
if ($Mode -eq 'deps')      { $WantDeps = $true;  $Mode = 'now' }
if ($Mode -eq 'check')     { $CheckOnly = $true; $Mode = 'now' }

$FlutterGitUrl = 'https://github.com/flutter/flutter.git'
$FlutterHome   = Join-Path $env:USERPROFILE 'development\flutter'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Stop-WithError($msg) {
  Write-Host "[error] $msg" -ForegroundColor Red
  exit 1
}

# This script is for Windows. (PowerShell 7 on macOS/Linux sets $IsWindows.)
if ($null -ne $IsWindows -and -not $IsWindows) {
  Stop-WithError "This installer is for Windows. On macOS or Linux, run: ./scripts/install.sh"
}

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

function Test-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# First line of a command's output, or '' if it fails.
function Get-FirstLine([scriptblock]$Block) {
  try { return [string](& $Block 2>$null | Select-Object -First 1) } catch { return '' }
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Prepend a directory to this session's PATH (no-op if already present).
function Add-SessionPath($dir) {
  if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

# Add a directory to the persisted *user* PATH (asks first) and this session.
function Add-UserPath($dir) {
  Add-SessionPath $dir
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -and (($userPath -split ';') -contains $dir)) { return }
  if (Confirm-Step "Add $dir to your user PATH so new terminals find it?") {
    $newPath = if ($userPath) { "$dir;$userPath" } else { $dir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Step "Added to your user PATH: $dir"
  } else {
    Write-Warn "Not saved. In new terminals, run first:  `$env:Path = '$dir;' + `$env:Path"
  }
}

# Refresh this session's PATH from the persisted machine + user environment
# (a newly installed package updates those, but not the running process), then
# add common Git / Flutter install locations if they still aren't resolvable.
function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'

  if (-not (Test-Cmd git)) {
    foreach ($dir in @("$env:ProgramFiles\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")) {
      if (Test-Path (Join-Path $dir 'git.exe')) { Add-SessionPath $dir; break }
    }
  }
  if (Test-Cmd flutter) { return }
  $candidates = @(
    (Join-Path $FlutterHome 'bin'),
    "$env:LOCALAPPDATA\flutter\bin",
    "$env:USERPROFILE\flutter\bin",
    'C:\src\flutter\bin',
    'C:\flutter\bin',
    'C:\tools\flutter\bin'
  )
  foreach ($dir in $candidates) {
    if (Test-Path (Join-Path $dir 'flutter.bat')) {
      Add-SessionPath $dir
      Write-Step "Added Flutter to this session's PATH: $dir"
      return
    }
  }
}

# --- Detection -------------------------------------------------------------

function Get-VsWherePath {
  $p = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path $p) { return $p } else { return $null }
}

# Name of a Visual Studio install that has the MSVC C++ tools, or $null.
function Get-VsCppInstall {
  $vswhere = Get-VsWherePath
  if (-not $vswhere) { return $null }
  try {
    $name = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName 2>$null
    if ($LASTEXITCODE -eq 0 -and $name) { return [string]($name | Select-Object -First 1) }
  } catch { }
  return $null
}

# Developer Mode lets non-admin users create the symlinks Flutter plugins use.
function Test-DeveloperMode {
  try {
    $v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
           -Name AllowDevelopmentWithoutDevLicense -ErrorAction Stop
    return ($v.AllowDevelopmentWithoutDevLicense -eq 1)
  } catch { return $false }
}

function Get-ChromePath {
  if ($env:CHROME_EXECUTABLE -and (Test-Path $env:CHROME_EXECUTABLE)) { return $env:CHROME_EXECUTABLE }
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    $p = Join-Path $base 'Google\Chrome\Application\chrome.exe'
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Test-Edge {
  foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if ($base -and (Test-Path (Join-Path $base 'Microsoft\Edge\Application\msedge.exe'))) { return $true }
  }
  return $false
}

# SQLite on Windows ships inside the app via the sqlite3_flutter_libs package.
function Test-SqliteBundled {
  return [bool](Select-String -Path (Join-Path $ProjectRoot 'pubspec.yaml') -Pattern '^\s*sqlite3_flutter_libs:' -Quiet)
}

$script:Missing = @()
function Write-Ok($name, $detail)       { Write-Host ("  [ok]       {0,-30} {1}" -f $name, $detail) -ForegroundColor Green }
function Write-Missing($name, $detail)  { Write-Host ("  [missing]  {0,-30} {1}" -f $name, $detail) -ForegroundColor Red; $script:Missing += $name }
function Write-Optional($name, $detail) { Write-Host ("  [optional] {0,-30} {1}" -f $name, $detail) -ForegroundColor Yellow }

function Invoke-Checks {
  $script:Missing = @()
  Write-Step "Checking what's installed for a $Platform build..."

  if (Test-Cmd winget)    { Write-Ok 'winget' (Get-FirstLine { winget --version }) }
  elseif (Test-Cmd choco) { Write-Ok 'Chocolatey' (Get-FirstLine { choco --version }) }
  else { Write-Optional 'winget' 'used to install the tools below ("App Installer" in the Microsoft Store)' }

  if (Test-Cmd git) { Write-Ok 'Git' (Get-FirstLine { git --version }) }
  else { Write-Missing 'Git' 'winget install --id Git.Git -e' }

  if (Test-Cmd flutter) { Write-Ok 'Flutter' (Get-FirstLine { flutter --version }) }
  else { Write-Missing 'Flutter' "git clone -b stable $FlutterGitUrl $FlutterHome" }

  if ($Platform -eq 'windows') {
    $vs = Get-VsCppInstall
    if ($vs) { Write-Ok 'Visual Studio C++ tools' $vs }
    else { Write-Missing 'Visual Studio C++ tools' 'Visual Studio 2022 Build Tools, "Desktop development with C++"' }
  }

  if (Test-DeveloperMode)  { Write-Ok 'Developer Mode' 'on' }
  elseif (Test-IsAdmin)    { Write-Optional 'Developer Mode' 'off (fine while running as administrator)' }
  else { Write-Missing 'Developer Mode' 'needed by plugins: Settings > For developers > Developer Mode' }

  if (Test-SqliteBundled) { Write-Ok 'SQLite' 'bundled by sqlite3_flutter_libs (nothing to install)' }
  else { Write-Optional 'SQLite' 'sqlite3_flutter_libs not found in pubspec.yaml' }

  if ($Platform -eq 'web') {
    $chrome = Get-ChromePath
    if ($chrome) { Write-Ok 'Google Chrome' $chrome }
    elseif (Test-Edge) { Write-Optional 'Google Chrome' 'not found; Microsoft Edge will be used instead' }
    else { Write-Optional 'Google Chrome' 'optional; any browser works without it' }
  }
}

# --- Install helpers -----------------------------------------------------------

# Install a package with winget (preferred) or Chocolatey. Returns $true on success.
function Install-Pkg($label, $wingetId, $chocoId, $wingetOverride, $chocoParams) {
  if (Test-Cmd winget) {
    Write-Step "Installing $label with winget..."
    $wingetArgs = @('install', '--id', $wingetId, '-e', '--source', 'winget',
                    '--accept-source-agreements', '--accept-package-agreements')
    if ($wingetOverride) { $wingetArgs += @('--override', $wingetOverride) }
    & winget @wingetArgs | Out-Host
  } elseif (Test-Cmd choco) {
    if (-not (Test-IsAdmin)) { Write-Warn "Chocolatey usually needs an administrator PowerShell." }
    Write-Step "Installing $label with Chocolatey..."
    $chocoArgs = @('install', $chocoId, '-y')
    if ($chocoParams) { $chocoArgs += @('--package-parameters', $chocoParams) }
    & choco @chocoArgs | Out-Host
  } else {
    Write-Warn "Can't install ${label}: neither winget nor Chocolatey is available."
    return $false
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "$label install reported exit code $LASTEXITCODE. Scroll up for details."
    Update-SessionPath
    return $false
  }
  Update-SessionPath
  return $true
}

# Official stable checkout of Flutter into %USERPROFILE%\development\flutter.
function Install-FlutterGit {
  $bin = Join-Path $FlutterHome 'bin'
  if (Test-Path (Join-Path $bin 'flutter.bat')) {
    Write-Step "Flutter is already in $FlutterHome"
  } else {
    if (-not (Test-Cmd git)) { Write-Warn "Git is needed to download Flutter. Install Git first, then re-run."; return }
    if (Test-Path $FlutterHome) { Write-Warn "$FlutterHome already exists but isn't a Flutter SDK. Move it aside, then re-run."; return }
    if ($FlutterHome -match ' ') { Write-Warn "Your user folder contains a space; Flutter may have trouble with that path." }
    if (-not (Confirm-Step "Download Flutter (stable) from $FlutterGitUrl into $FlutterHome? (about 1-2 GB)")) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FlutterHome) | Out-Null
    Write-Step "Downloading Flutter (this can take a while)..."
    & git clone -b stable $FlutterGitUrl $FlutterHome
    if ($LASTEXITCODE -ne 0) { Write-Warn "Downloading Flutter failed. Check your internet connection and try again."; return }
  }
  Add-UserPath $bin
}

# Windows dependency bootstrap. Every install asks first.
function Invoke-Bootstrap {
  Write-Step "Installing prerequisites..."
  if (-not (Test-Cmd winget) -and -not (Test-Cmd choco)) {
    Write-Warn "Neither winget nor Chocolatey is available, so nothing can be installed automatically."
    Write-Warn "Install 'App Installer' (winget) from the Microsoft Store, then re-run with -Deps."
    Write-Warn "Or follow the manual guide: https://docs.flutter.dev/get-started/install/windows"
  }

  # Git.
  if (Test-Cmd git) { Write-Step ("Git: " + (Get-FirstLine { git --version })) }
  elseif (Confirm-Step "Install Git?") { Install-Pkg 'Git' 'Git.Git' 'git' $null $null | Out-Null }

  # Flutter.
  if (Test-Cmd flutter) { Write-Step ("Flutter: " + (Get-FirstLine { flutter --version })) }
  else { Install-FlutterGit }

  # Visual Studio C++ build tools (Windows desktop app only).
  if ($Platform -eq 'windows') {
    $vs = Get-VsCppInstall
    if ($vs) {
      Write-Step "Visual Studio C++ tools: $vs"
    } elseif (Confirm-Step 'Install Visual Studio 2022 Build Tools with "Desktop development with C++" (large download, several GB)?') {
      $components = '--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --includeRecommended'
      Install-Pkg 'Visual Studio Build Tools' 'Microsoft.VisualStudio.2022.BuildTools' 'visualstudio2022buildtools' `
        "--wait --passive --norestart $components" "$components --passive" | Out-Null
      if (-not (Get-VsCppInstall)) {
        Write-Warn "The C++ tools weren't detected yet. If the Visual Studio Installer is still running, let it finish, then re-run."
      }
    }
  }

  # Developer Mode (symlinks for plugins). Changing it is done in Settings.
  if (-not (Test-DeveloperMode) -and -not (Test-IsAdmin)) {
    Write-Warn "Windows Developer Mode is off. Flutter plugins need it to create shortcuts (symlinks)."
    Write-Warn "Turn it on in: Settings > System > For developers > Developer Mode."
    if (Confirm-Step "Open that Settings page now?") {
      Start-Process 'ms-settings:developers'
      Write-Step "After switching it on, re-run this installer."
    }
  }

  # Chrome (web only, optional; Edge or any browser also works).
  if ($Platform -eq 'web' -and -not (Get-ChromePath)) {
    if (Confirm-Step "Optional: install Google Chrome for the web version?") {
      Install-Pkg 'Google Chrome' 'Google.Chrome' 'googlechrome' $null $null | Out-Null
    }
  }
}

# Resolve the project root (parent of this scripts\ directory).
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# --- 0. Check / install prerequisites --------------------------------------
Update-SessionPath

if ($CheckOnly) {
  Invoke-Checks
  if (Test-Cmd flutter) {
    Write-Step "Flutter's own health check (flutter doctor):"
    & flutter doctor
  }
  if ($script:Missing.Count -eq 0) {
    Write-Step "Everything needed for a $Platform build is installed."
    exit 0
  }
  Write-Warn ("Missing: " + ($script:Missing -join ', '))
  Write-Warn "Install them automatically with:  .\scripts\install.ps1 $Platform -Deps"
  exit 1
}

$Bootstrapped = $false
if ($WantDeps) {
  Invoke-Bootstrap
  $Bootstrapped = $true
} else {
  Invoke-Checks
  if ($script:Missing.Count -gt 0) {
    Write-Warn ("Missing: " + ($script:Missing -join ', '))
    if (Confirm-Step "Install the missing prerequisites now?") {
      Invoke-Bootstrap
      $Bootstrapped = $true
    }
  }
}

# --- 1. Flutter SDK check -------------------------------------------------
if (-not (Test-Cmd flutter)) { Update-SessionPath }
if (-not (Test-Cmd flutter)) {
  if ($Bootstrapped) {
    Write-Warn "Flutter may have just been installed, but this window can't see it yet."
    Write-Warn "Close this window, open a NEW PowerShell, and re-run:  .\scripts\install.ps1 $Platform"
  }
  Stop-WithError "Flutter isn't installed (or isn't on your PATH). Install it automatically with '.\scripts\install.ps1 $Platform -Deps', or manually from https://docs.flutter.dev/get-started/install/windows"
}
Write-Step ("Flutter found: " + (Get-FirstLine { flutter --version }))

# --- 2. Enable the target platform ---------------------------------------
switch ($Platform) {
  'windows' { flutter config --enable-windows-desktop | Out-Null }
  'web'     { flutter config --enable-web | Out-Null }
}
Write-Step "Platform enabled: $Platform"

if ($Bootstrapped) {
  Write-Step "Flutter's health check (flutter doctor). Items unrelated to $Platform can be ignored:"
  & flutter doctor
}

# --- 3. Install dependencies ---------------------------------------------
Write-Step "Installing Dart/Flutter package dependencies..."
& flutter pub get
if ($LASTEXITCODE -ne 0) {
  Stop-WithError "Couldn't download the app's packages. If the message mentions 'symlink', turn on Developer Mode (Settings > System > For developers). Otherwise check your internet connection, then re-run."
}

if ($Platform -eq 'web') {
  Write-Step "Setting up SQLite WASM assets for web..."
  & dart run sqflite_common_ffi_web:setup
  if ($LASTEXITCODE -ne 0) { Write-Warn "sqflite web setup reported an error; existing web\ assets will be used." }
}

# --- 4. Build ------------------------------------------------------------
Write-Step "Building the app for $Platform (first run can take a few minutes)..."
switch ($Platform) {
  'windows' { & flutter build windows }
  'web'     { & flutter build web }
}
if ($LASTEXITCODE -ne 0) {
  Stop-WithError "The build failed. The first error above explains why. To see what's missing, run:  .\scripts\install.ps1 $Platform check"
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
# Web: Chrome if present, else Edge, else serve for any browser.
$webDevice = 'chrome'
if ($Platform -eq 'web' -and -not (Get-ChromePath)) {
  if (Test-Edge) { $webDevice = 'edge'; Write-Step "Chrome wasn't found, so Microsoft Edge will be used." }
  else { $webDevice = 'web-server'; Write-Step "Chrome wasn't found, so the app will be served for any browser you like." }
}

$runArgs = switch ($Platform) {
  'web'     { @('run', '-d', $webDevice, '--web-port', "$WebPort") }
  'windows' { @('run', '-d', 'windows') }
}

if ($Mode -eq 'background') {
  $logFile = Join-Path $ProjectRoot "spwrite-$Platform.log"
  Write-Step "Launching $Platform in the background. Logs: $logFile"
  $flutterExe = (Get-Command flutter).Source
  $proc = Start-Process -FilePath $flutterExe -ArgumentList $runArgs `
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
