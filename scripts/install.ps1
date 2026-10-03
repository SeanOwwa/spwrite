<#
.SYNOPSIS
  Spwrite installer for the Windows desktop app.

.DESCRIPTION
  1. Checks for Flutter and everything Windows needs to build Spwrite, and
     (with your permission) installs whatever is missing.
  2. Enables the target platform in Flutter.
  3. Installs the app's packages (flutter pub get).
  4. Builds and launches the app -- immediately in this terminal, or detached
     in the background.

  What gets installed (winget preferred, Chocolatey as a fallback):
    - Git
    - Flutter (official stable checkout in %USERPROFILE%\development\flutter,
      added to your user PATH)
    - For a Windows app: Visual Studio 2022 Build Tools with the
      "Desktop development with C++" workload (MSVC + Windows SDK)
  It also checks Windows Developer Mode, which Flutter plugins need for
  symlinks, and offers to open the Settings page to turn it on.
  SQLite needs no install: it is bundled by the sqlite3_flutter_libs package.

.PARAMETER Platform
  windows   (default: windows)

.PARAMETER Mode
  now | background   (default: now)

.PARAMETER Deps
  Install the prerequisites first, then continue with the normal build + run.
  Each install asks for confirmation first. The bare word 'deps' also works.
  Even without -Deps, the installer offers to install anything missing.

.PARAMETER Check
  Only report what is installed and what is missing, then exit. Changes
  nothing. The bare word 'check' also works.


.PARAMETER AssumeYes
  Answer "yes" to every confirmation prompt (non-interactive installs).

.EXAMPLE
  .\scripts\install.ps1 windows now
  .\scripts\install.ps1 windows background
  .\scripts\install.ps1 windows -Deps
  .\scripts\install.ps1 deps
  .\scripts\install.ps1 windows check
#>
param(
  # 'web' is accepted only to explain that it is no longer offered.
  [ValidateSet('windows', 'web', 'deps', 'check')]
  [string]$Platform = 'windows',

  [ValidateSet('now', 'background', 'deps', 'check')]
  [string]$Mode = 'now',


  [switch]$Deps,

  [switch]$Check,

  [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'

# Accept the bare words 'deps' / 'check' in either positional slot, then
# normalize the platform/mode back to their real defaults.
$WantDeps  = [bool]$Deps
$CheckOnly = [bool]$Check
if ($Platform -eq 'deps')  { $WantDeps = $true;  $Platform = 'windows' }
if ($Platform -eq 'check') { $CheckOnly = $true; $Platform = 'windows' }
# Windows on ARM: the build would target ARM64, which isn't supported.
$IsArmPc = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
if ($IsArmPc -and -not $CheckOnly) {
  Write-Host "[error] Spwrite can't be built on Windows on ARM: its AI engine (llama.cpp) doesn't compile with MSVC on ARM64." -ForegroundColor Red
  Write-Host "        Download the x64 version from the website instead; Windows 11 on ARM runs it through built-in emulation." -ForegroundColor Red
  exit 1
}
if ($Platform -eq 'web') {
  Write-Host "[error] The web version is no longer offered. Build the desktop app instead: .\scripts\install.ps1 windows" -ForegroundColor Red
  exit 1
}
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

}

# Copies the built Release folder to a real install location and adds Desktop
# and Start menu shortcuts. Shortcuts are the reliable way to open Spwrite from
# the Desktop: the .exe must stay next to its DLLs and its data folder, and a
# Desktop that OneDrive syncs can leave copied files "online-only".
function Install-SpwriteApp($releaseDir) {
  $target = Join-Path $env:LOCALAPPDATA 'Programs\Spwrite'
  if (-not (Confirm-Step "Install Spwrite to $target and add Desktop and Start menu shortcuts?")) {
    Write-Step "Skipped. Run it from: $releaseDir\spwrite.exe (keep that whole folder together)."
    return
  }
  if (Test-Path $target) { Remove-Item -Recurse -Force $target }
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Copy-Item -Path (Join-Path $releaseDir '*') -Destination $target -Recurse -Force
  Get-ChildItem -Recurse $target | Unblock-File -ErrorAction SilentlyContinue

  $exePath = Join-Path $target 'spwrite.exe'
  $shell = New-Object -ComObject WScript.Shell
  $desktop = [Environment]::GetFolderPath('Desktop')
  $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Spwrite.lnk'
  foreach ($lnkPath in @((Join-Path $desktop 'Spwrite.lnk'), $startMenu)) {
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $exePath
    $lnk.WorkingDirectory = $target   # the app looks for data\ next to itself
    $lnk.IconLocation = "$exePath,0"
    $lnk.Save()
  }
  Write-Step "Installed to $target"
  Write-Step "Open Spwrite from the Desktop shortcut or the Start menu."
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


# --- 4. Build ------------------------------------------------------------
Write-Step "Building the app for $Platform (first run can take a few minutes)..."
switch ($Platform) {
  'windows' { & flutter build windows }
}
if ($LASTEXITCODE -ne 0) {
  Stop-WithError "The build failed. The first error above explains why. To see what's missing, run:  .\scripts\install.ps1 $Platform check"
}
Write-Step "Build complete."

# Point the user at the finished, standalone artifact.
switch ($Platform) {
  'windows' {
    # x64 or arm64, depending on this PC.
    $exe = Get-ChildItem -Path 'build\windows' -Recurse -Filter 'spwrite.exe' -ErrorAction SilentlyContinue |
      Where-Object { $_.DirectoryName -like '*\runner\Release' } | Select-Object -First 1
    if ($exe) {
      Write-Step "Your app is ready: $($exe.FullName)"
      Install-SpwriteApp $exe.Directory.FullName
    }
  }
}

# --- 5. Launch -----------------------------------------------------------

$runArgs = switch ($Platform) {
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
}
else {
  Write-Step "Launching $Platform in this terminal (Ctrl+C to stop)..."
  & flutter @runArgs
}
