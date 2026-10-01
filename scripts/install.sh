#!/usr/bin/env bash
#
# Spwrite installer for macOS, Linux, and Web.
#
# What it does:
#   1. Checks for Flutter and everything your computer needs to build Spwrite,
#      and (with your permission) installs whatever is missing.
#   2. Enables the target platform in Flutter.
#   3. Installs the app's packages (`flutter pub get`, plus the SQLite WASM
#      assets for web).
#   4. Builds and launches the app -- either immediately in the foreground
#      (terminal) or detached in the background.
#
# Usage:
#   ./scripts/install.sh [PLATFORM] [MODE] [deps] [check]
#
#   PLATFORM : macos | linux | web        (default: web)
#   MODE     : now | background           (default: now)
#
#   Extra words (usable in any position):
#     deps   Install the prerequisites first (Flutter, Git and the platform
#            build tools), then continue with the normal build + run.
#     check  Only report what is installed and what is missing. Changes
#            nothing on your computer, then exits.
#
#   Even without `deps`, the installer offers to install anything missing.
#   Every step that changes your system (installing software, using sudo,
#   editing your shell profile) asks for confirmation first.
#
#   What gets installed:
#     macOS : Homebrew, Xcode Command Line Tools, Git, Flutter
#             + for macOS apps: full Xcode setup (license / first launch), CocoaPods
#             + for web (optional): Google Chrome
#     Linux : apt / dnf / pacman / zypper packages (git, curl, unzip, xz, zip)
#             + for Linux apps: clang, cmake, ninja, pkg-config, GTK 3, lzma,
#               libstdc++, SQLite, libsecret and GLU development files
#             Flutter via snap, or the official stable git checkout in
#             ~/development/flutter
#             + for web (optional): Chromium
#
# Environment variables:
#   ASSUME_YES=1   Answer "yes" to every prompt (unattended installs).
#   WEB_PORT=9000  Port for the web version (default: 8080).
#   WEB_HOST=0.0.0.0  Address the web version listens on (default: localhost).
#                  Only change this on a trusted network: the dev server has
#                  no login. On a remote server, prefer an SSH tunnel instead.
#
# Servers without a screen (e.g. Ubuntu Server): the Linux app needs a
# graphical desktop to open its window. The installer detects this, still
# builds the app, and offers to set up a remote desktop (XFCE + xrdp) so you
# can open Spwrite from your own computer.
#
# Examples:
#   ./scripts/install.sh web now           # build + run web in this terminal
#   ./scripts/install.sh macos background  # build + run macOS detached
#   ./scripts/install.sh linux now
#   ./scripts/install.sh macos deps        # install prerequisites, then run
#   ./scripts/install.sh deps              # install prerequisites for web, then run
#   ./scripts/install.sh macos check       # just report what's missing
#
set -euo pipefail

# --- Arguments ------------------------------------------------------------
# `deps` and `check` may appear in any positional slot; pull them out and
# leave PLATFORM / MODE with their normal values.
WANT_DEPS=0
CHECK_ONLY=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    deps) WANT_DEPS=1 ;;
    check | --check | --dry-run) CHECK_ONLY=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

PLATFORM="${ARGS[0]:-web}"
MODE="${ARGS[1]:-now}"
WEB_PORT="${WEB_PORT:-8080}"
WEB_HOST="${WEB_HOST:-localhost}"
ASSUME_YES="${ASSUME_YES:-0}"
HOST_OS="$(uname -s)"

# A Linux machine with no graphical session (Ubuntu Server, SSH without X
# forwarding, containers) has neither DISPLAY nor WAYLAND_DISPLAY set. The
# Linux desktop app cannot open a window there.
HEADLESS=0
if [ "$HOST_OS" = "Linux" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  HEADLESS=1
fi

# Official Flutter repository (used for the git fallback install).
FLUTTER_GIT_URL="https://github.com/flutter/flutter.git"
FLUTTER_HOME_DEFAULT="$HOME/development/flutter"

# Resolve the project root (the parent of this scripts/ directory) so the
# installer works no matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Ask the user a yes/no question. Returns 0 for yes, 1 for no. Honors
# ASSUME_YES=1 (always yes) and defaults to "no" when there is no TTY so an
# unattended run never blocks or silently escalates privileges.
confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = "1" ]; then
    log "$prompt -> yes (ASSUME_YES)"
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "$prompt -> no (no interactive terminal; skipping)"
    return 1
  fi
  local reply
  printf '\033[1;35m[?]\033[0m %s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Validate the request early -------------------------------------------
case "$PLATFORM" in
  macos | linux | web) ;;
  windows) die "Windows builds use the PowerShell installer: .\\scripts\\install.ps1 windows" ;;
  *) die "Unknown platform '$PLATFORM'. Use: macos | linux | web" ;;
esac
case "$MODE" in
  now | background) ;;
  *) die "Unknown mode '$MODE'. Use: now | background (plus optional 'deps' or 'check')" ;;
esac
case "$HOST_OS" in
  Darwin | Linux) ;;
  *) die "This installer supports macOS and Linux. On Windows, use .\\scripts\\install.ps1" ;;
esac
if [ "$PLATFORM" = "macos" ] && [ "$HOST_OS" != "Darwin" ]; then
  die "A macOS app can only be built on a Mac. Try: ./scripts/install.sh linux  (or web)"
fi
if [ "$PLATFORM" = "linux" ] && [ "$HOST_OS" != "Linux" ]; then
  die "A Linux app can only be built on Linux. Try: ./scripts/install.sh macos  (or web)"
fi

# --- PATH helpers -----------------------------------------------------------

# Prepend a directory to PATH for this run (no-op if already present).
path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) export PATH="$1:$PATH" ;;
  esac
}

# The shell profile file where PATH changes should be saved.
shell_rc_file() {
  case "$(basename "${SHELL:-}")" in
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    bash)
      if [ "$HOST_OS" = "Darwin" ]; then printf '%s\n' "$HOME/.bash_profile"
      else printf '%s\n' "$HOME/.bashrc"; fi ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

# Offer to append a line to a shell profile so a setting survives new
# terminals. Idempotent: does nothing if the exact line is already there.
persist_line() {
  local line="$1" what="$2" rc="${3:-$(shell_rc_file)}"
  if [ -f "$rc" ] && grep -qxF "$line" "$rc"; then
    return 0
  fi
  if confirm "Save $what to $rc so new terminals find it?"; then
    printf '\n# Added by the Spwrite installer\n%s\n' "$line" >>"$rc"
    log "Saved to $rc"
  else
    warn "Not saved. In new terminals, run first:  $line"
  fi
}

# Pick up tools that are installed but not on PATH in this shell (Homebrew on
# Apple Silicon / Intel, a git checkout of Flutter, snap binaries). Only
# affects this run; nothing is written to disk.
load_known_paths() {
  if [ "$HOST_OS" = "Darwin" ] && ! have brew; then
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  if ! have flutter; then
    if [ -x "$FLUTTER_HOME_DEFAULT/bin/flutter" ]; then
      path_prepend "$FLUTTER_HOME_DEFAULT/bin"
    elif [ -x /snap/bin/flutter ]; then
      path_prepend /snap/bin
    fi
  fi
}

# Print the first line of a command's output, never failing the script.
first_line() { { "$@" 2>/dev/null || true; } | head -n 1; }

# --- Status report (used by `check` and to decide whether to offer installs) --
REQUIRED_MISSING=()
report_ok()       { printf '  \033[1;32m[ok]\033[0m       %-28s %s\n' "$1" "${2:-}"; }
report_missing()  { printf '  \033[1;31m[missing]\033[0m  %-28s %s\n' "$1" "${2:-}"; REQUIRED_MISSING+=("$1"); }
report_optional() { printf '  \033[1;33m[optional]\033[0m %-28s %s\n' "$1" "${2:-}"; }

flutter_version() { first_line flutter --version; }

# --- macOS detection ------------------------------------------------------

clt_installed()   { xcode-select -p >/dev/null 2>&1; }
git_works()       { git --version >/dev/null 2>&1; }   # /usr/bin/git is a stub until the CLT exist
xcode_active()    { xcodebuild -version >/dev/null 2>&1; }
xcode_app_path() {
  if [ -d "/Applications/Xcode.app" ]; then
    printf '%s\n' "/Applications/Xcode.app"
  else
    find /Applications -maxdepth 1 -type d -name 'Xcode*.app' 2>/dev/null | head -n 1
  fi
}
xcode_license_ok() { xcodebuild -license check >/dev/null 2>&1; }
xcode_first_launch_ok() { xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; }

mac_chrome_path() {
  if [ -n "${CHROME_EXECUTABLE:-}" ] && [ -x "$CHROME_EXECUTABLE" ]; then
    printf '%s\n' "$CHROME_EXECUTABLE"; return 0
  fi
  local app
  for app in "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do
    if [ -d "$app" ]; then printf '%s\n' "$app"; return 0; fi
  done
  return 1
}

check_macos() {
  if have brew; then report_ok "Homebrew" "$(first_line brew --version)"
  else report_optional "Homebrew" "used to install the tools below (https://brew.sh)"; fi

  if clt_installed; then report_ok "Xcode Command Line Tools" "$(xcode-select -p)"
  else report_missing "Xcode Command Line Tools" "install with: xcode-select --install"; fi

  if git_works; then report_ok "Git" "$(first_line git --version)"
  else report_missing "Git" "comes with the Command Line Tools, or: brew install git"; fi

  if have flutter; then report_ok "Flutter" "$(flutter_version)"
  else report_missing "Flutter" "brew install --cask flutter"; fi

  if [ "$PLATFORM" = "macos" ]; then
    if xcode_active; then
      report_ok "Xcode" "$(first_line xcodebuild -version)"
      if xcode_license_ok; then report_ok "Xcode license" "accepted"
      else report_missing "Xcode license" "sudo xcodebuild -license accept"; fi
      if xcode_first_launch_ok; then report_ok "Xcode first-launch setup" "done"
      else report_missing "Xcode first-launch setup" "sudo xcodebuild -runFirstLaunch"; fi
    elif [ -n "$(xcode_app_path)" ]; then
      report_missing "Xcode (not selected)" "installed at $(xcode_app_path) but not active"
    else
      report_missing "Xcode" "free from the Mac App Store (needed for macOS apps)"
    fi
    if have pod; then report_ok "CocoaPods" "$(first_line pod --version)"
    else report_missing "CocoaPods" "brew install cocoapods"; fi
  fi

  if [ "$PLATFORM" = "web" ]; then
    local chrome
    if chrome="$(mac_chrome_path)"; then report_ok "Google Chrome" "$chrome"
    else report_optional "Google Chrome" "brew install --cask google-chrome (any browser works without it)"; fi
  fi
}

# --- Linux detection --------------------------------------------------------

LINUX_PM=""
detect_linux_pm() {
  if have apt-get; then LINUX_PM="apt"
  elif have dnf; then LINUX_PM="dnf"
  elif have pacman; then LINUX_PM="pacman"
  elif have zypper; then LINUX_PM="zypper"
  else LINUX_PM=""; fi
}

# First apt package from the arguments that the package index knows about.
apt_pick() {
  local p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; return 0; fi
  done
  printf '%s\n' "$1"
}

# Package list for the detected package manager. Base packages are what
# Flutter itself needs; desktop packages are only needed for a Linux app.
linux_packages() {
  local base="" desktop=""
  case "$LINUX_PM" in
    apt)
      base="curl git unzip xz-utils zip"
      desktop="build-essential clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev $(apt_pick libstdc++-12-dev libstdc++-13-dev libstdc++-14-dev libstdc++-11-dev) libsqlite3-dev libsecret-1-dev libglu1-mesa"
      ;;
    dnf)
      base="curl git unzip xz zip which"
      desktop="gcc gcc-c++ clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel sqlite-devel libsecret-devel mesa-libGLU"
      ;;
    pacman)
      base="curl git unzip xz zip which"
      desktop="gcc clang cmake ninja pkgconf gtk3 gcc-libs sqlite libsecret glu"
      ;;
    zypper)
      base="curl git unzip xz zip which"
      desktop="gcc gcc-c++ clang cmake ninja pkg-config gtk3-devel xz-devel libstdc++-devel sqlite3-devel libsecret-devel glu-devel"
      ;;
  esac
  if [ "$PLATFORM" = "linux" ]; then
    printf '%s %s\n' "$base" "$desktop"
  else
    printf '%s\n' "$base"
  fi
}

linux_pkg_installed() {
  case "$LINUX_PM" in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    dnf | zypper) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    pacman) pacman -T "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Space-separated list of packages that still need installing.
linux_missing_packages() {
  local p missing=""
  for p in $(linux_packages); do
    linux_pkg_installed "$p" || missing="$missing $p"
  done
  printf '%s\n' "${missing# }"
}

# Find Chrome or Chromium; Flutter needs CHROME_EXECUTABLE for Chromium.
linux_chrome_path() {
  if [ -n "${CHROME_EXECUTABLE:-}" ] && [ -x "$CHROME_EXECUTABLE" ]; then
    printf '%s\n' "$CHROME_EXECUTABLE"; return 0
  fi
  local b
  for b in google-chrome google-chrome-stable chromium chromium-browser; do
    if have "$b"; then command -v "$b"; return 0; fi
  done
  [ -x /snap/bin/chromium ] && { printf '%s\n' /snap/bin/chromium; return 0; }
  return 1
}

check_linux() {
  detect_linux_pm
  if [ -z "$LINUX_PM" ]; then
    report_missing "Package manager" "none of apt / dnf / pacman / zypper found"
  else
    report_ok "Package manager" "$LINUX_PM"
    local missing
    missing="$(linux_missing_packages)"
    if [ -z "$missing" ]; then report_ok "System packages" "all present"
    else report_missing "System packages" "$missing"; fi
  fi

  if have flutter; then report_ok "Flutter" "$(flutter_version)"
  elif have snap; then report_missing "Flutter" "sudo snap install flutter --classic"
  else report_missing "Flutter" "git clone -b stable $FLUTTER_GIT_URL $FLUTTER_HOME_DEFAULT"; fi

  if [ "$PLATFORM" = "web" ]; then
    local chrome
    if chrome="$(linux_chrome_path)"; then report_ok "Chrome / Chromium" "$chrome"
    else report_optional "Chrome / Chromium" "optional; any browser works without it"; fi
  fi
}

run_checks() {
  REQUIRED_MISSING=()
  log "Checking what's installed for a $PLATFORM build on $HOST_OS..."
  case "$HOST_OS" in
    Darwin) check_macos ;;
    Linux)  check_linux ;;
  esac
}

# --- Shared install helpers -------------------------------------------------

# Run a command as administrator (or directly if already root).
as_root() {
  if [ "$(id -u)" = "0" ]; then "$@"
  elif have sudo; then sudo "$@"
  else die "Administrator rights are needed for: $* -- but 'sudo' isn't available. Run it as root, then re-run the installer."
  fi
}

# Official fallback: clone the stable channel of Flutter into
# ~/development/flutter and add it to PATH.
install_flutter_git() {
  local dir="$FLUTTER_HOME_DEFAULT"
  if [ -x "$dir/bin/flutter" ]; then
    log "Flutter is already in $dir"
  else
    git_works || { warn "Git is needed to download Flutter. Install Git first, then re-run."; return 1; }
    if [ -e "$dir" ]; then
      warn "$dir already exists but isn't a Flutter SDK. Move it aside, then re-run."
      return 1
    fi
    confirm "Download Flutter (stable) from $FLUTTER_GIT_URL into $dir? (about 1-2 GB)" || return 1
    mkdir -p "$(dirname "$dir")"
    log "Downloading Flutter (this can take a while)..."
    git clone -b stable "$FLUTTER_GIT_URL" "$dir" || { warn "Downloading Flutter failed. Check your internet connection and try again."; return 1; }
  fi
  path_prepend "$dir/bin"
  # shellcheck disable=SC2016  # $PATH must expand when the profile runs, not now.
  persist_line "export PATH=\"$dir/bin:\$PATH\"" "Flutter's location"
}

# --- macOS install ------------------------------------------------------------

bootstrap_macos() {
  # 1. Homebrew (the only remote script we run, from the official repo).
  if ! have brew; then
    if confirm "Homebrew (the Mac package manager) is not installed. Install it now with the official installer from brew.sh?"; then
      log "Installing Homebrew (you may be asked for your password)..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || warn "The Homebrew installer reported a problem. See https://brew.sh for help."
      local brew_bin=""
      if [ -x /opt/homebrew/bin/brew ]; then brew_bin=/opt/homebrew/bin/brew      # Apple Silicon
      elif [ -x /usr/local/bin/brew ]; then brew_bin=/usr/local/bin/brew; fi     # Intel
      if [ -n "$brew_bin" ]; then
        eval "$("$brew_bin" shellenv)"
        local profile="$HOME/.zprofile"
        [ "$(basename "${SHELL:-}")" = "bash" ] && profile="$HOME/.bash_profile"
        persist_line "eval \"\$($brew_bin shellenv)\"" "Homebrew's location" "$profile"
      fi
    else
      warn "Skipping Homebrew. Flutter can still be downloaded with Git."
    fi
  fi
  have brew && log "Homebrew: $(first_line brew --version)"

  # 2. Xcode Command Line Tools (clang, git, make).
  if clt_installed; then
    log "Xcode Command Line Tools: $(xcode-select -p)"
  elif confirm "Install Apple's Xcode Command Line Tools (opens Apple's installer window)?"; then
    xcode-select --install || warn "xcode-select reported a non-zero status; it may already be installing."
    log "Finish Apple's installer window, then re-run this script if anything below fails."
  fi

  # 3. Git.
  if git_works; then
    log "Git: $(first_line git --version)"
  elif have brew && confirm "Install Git with 'brew install git'?"; then
    brew install git || warn "brew install git reported a problem."
  else
    warn "Git isn't available yet. It arrives with the Command Line Tools."
  fi

  # 4. Flutter: Homebrew cask first, official git checkout as fallback.
  if have flutter; then
    log "Flutter: $(flutter_version)"
  else
    if have brew && confirm "Install Flutter with 'brew install --cask flutter'?"; then
      log "Installing Flutter (this downloads the SDK; can take a while)..."
      brew install --cask flutter || warn "Homebrew couldn't install Flutter."
    fi
    have flutter || install_flutter_git || true
  fi

  # 5. macOS desktop app: full Xcode + CocoaPods.
  if [ "$PLATFORM" = "macos" ]; then
    ensure_full_xcode
    ensure_cocoapods
  fi

  # 6. Web: Chrome is optional (any browser can open the web-server URL).
  if [ "$PLATFORM" = "web" ] && ! mac_chrome_path >/dev/null; then
    if have brew && confirm "Optional: install Google Chrome with 'brew install --cask google-chrome'?"; then
      brew install --cask google-chrome || warn "Chrome install reported a problem; you can use any browser instead."
    fi
  fi
}

# Make the full Xcode toolchain usable for a macOS build: Xcode.app installed,
# selected as the active developer directory, license accepted, and the
# first-launch components installed. Each sudo step asks first.
ensure_full_xcode() {
  if ! xcode_active; then
    local xcode_app
    xcode_app="$(xcode_app_path)"
    if [ -z "$xcode_app" ]; then
      warn "Building a Mac desktop app needs the full Xcode app, which isn't installed."
      warn "Xcode is free but only comes from the Mac App Store (it can't be installed by script)."
      warn "Install it, open it once, then re-run:  ./scripts/install.sh macos deps"
      warn "(Tip: the web version doesn't need Xcode:  ./scripts/install.sh web)"
      if confirm "Open Xcode's page in the App Store now?"; then
        open "macappstores://apps.apple.com/app/id497799835" || true
      fi
      return
    fi
    local active
    active="$(xcode-select -p 2>/dev/null || true)"
    warn "Xcode is installed at $xcode_app, but the active tools are: ${active:-<none>}"
    if confirm "Switch to the full Xcode with 'sudo xcode-select --switch $xcode_app/Contents/Developer'?"; then
      sudo xcode-select --switch "$xcode_app/Contents/Developer" || warn "Switching Xcode failed."
    else
      warn "Skipped. Run that command yourself, then re-run the installer."
      return
    fi
  fi

  if ! xcode_license_ok; then
    if confirm "Accept the Xcode license with 'sudo xcodebuild -license accept'?"; then
      sudo xcodebuild -license accept || warn "Accepting the license failed; open Xcode once to accept it."
    else
      warn "The Xcode license must be accepted before building. Run: sudo xcodebuild -license accept"
    fi
  fi
  if ! xcode_first_launch_ok; then
    if confirm "Finish Xcode's first-launch setup with 'sudo xcodebuild -runFirstLaunch'?"; then
      sudo xcodebuild -runFirstLaunch || warn "First-launch setup failed; open Xcode once to finish it."
    else
      warn "Xcode setup isn't finished. Run: sudo xcodebuild -runFirstLaunch"
    fi
  fi

  if xcode_active; then
    log "Xcode: $(first_line xcodebuild -version)"
  else
    warn "Xcode still isn't ready. Open Xcode.app once to finish setup, then re-run."
  fi
}

# CocoaPods is needed to build the macOS plugins. Homebrew needs no sudo.
ensure_cocoapods() {
  if have pod; then
    log "CocoaPods: $(first_line pod --version)"
    return
  fi
  if have brew && confirm "CocoaPods is needed for macOS plugins. Install it with 'brew install cocoapods'?"; then
    brew install cocoapods || warn "brew install cocoapods reported a problem."
  else
    warn "CocoaPods is missing. Install it with: brew install cocoapods"
  fi
}

# --- Linux install ------------------------------------------------------------

bootstrap_linux() {
  detect_linux_pm
  if [ -z "$LINUX_PM" ]; then
    warn "No supported package manager (apt / dnf / pacman / zypper) was found."
    warn "Install the Flutter Linux prerequisites manually:"
    warn "  https://docs.flutter.dev/get-started/install/linux"
  else
    local missing
    missing="$(linux_missing_packages)"
    if [ -z "$missing" ]; then
      log "System packages: all present ($LINUX_PM)"
    elif confirm "Install these system packages with $LINUX_PM (needs your password): $missing ?"; then
      # Word splitting of $missing is intentional: one argument per package.
      # shellcheck disable=SC2086
      case "$LINUX_PM" in
        apt)    as_root apt-get update && as_root apt-get install -y $missing ;;
        dnf)    as_root dnf install -y $missing ;;
        pacman) as_root pacman -S --needed --noconfirm $missing ;;
        zypper) as_root zypper --non-interactive install $missing ;;
      esac || warn "Some packages failed to install. Scroll up for details, then re-run."
    else
      warn "Skipped system packages. The build may fail without them."
    fi
  fi

  # Flutter: snap if available, otherwise the official stable git checkout.
  if have flutter; then
    log "Flutter: $(flutter_version)"
  else
    if have snap && confirm "Install Flutter with 'sudo snap install flutter --classic'?"; then
      as_root snap install flutter --classic || warn "snap couldn't install Flutter."
      path_prepend /snap/bin
    fi
    have flutter || install_flutter_git || true
  fi

  # Web: Chrome/Chromium is optional; Flutter needs CHROME_EXECUTABLE for Chromium.
  if [ "$PLATFORM" = "web" ] && [ "$HEADLESS" = "0" ] && ! linux_chrome_path >/dev/null; then
    if confirm "Optional: install the Chromium browser for the web version?"; then
      if have snap; then as_root snap install chromium
      else
        case "$LINUX_PM" in
          apt)    as_root apt-get install -y chromium ;;
          dnf)    as_root dnf install -y chromium ;;
          pacman) as_root pacman -S --needed --noconfirm chromium ;;
          zypper) as_root zypper --non-interactive install chromium ;;
        esac
      fi || warn "Chromium install reported a problem; you can use any browser instead."
    fi
  fi
}

bootstrap() {
  log "Installing prerequisites..."
  case "$HOST_OS" in
    Darwin) bootstrap_macos ;;
    Linux)  bootstrap_linux ;;
  esac
}

# --- 0. Check / install prerequisites ---------------------------------------
load_known_paths

if [ "$CHECK_ONLY" = "1" ]; then
  run_checks
  if have flutter; then
    log "Flutter's own health check (flutter doctor):"
    flutter doctor || true
  fi
  if [ "${#REQUIRED_MISSING[@]}" -eq 0 ]; then
    log "Everything needed for a $PLATFORM build is installed."
    exit 0
  fi
  warn "Missing: $(printf '%s, ' "${REQUIRED_MISSING[@]}" | sed 's/, $//')"
  warn "Install them automatically with:  ./scripts/install.sh $PLATFORM deps"
  exit 1
fi

BOOTSTRAPPED=0
if [ "$WANT_DEPS" = "1" ]; then
  bootstrap
  BOOTSTRAPPED=1
else
  run_checks
  if [ "${#REQUIRED_MISSING[@]}" -gt 0 ]; then
    warn "Missing: $(printf '%s, ' "${REQUIRED_MISSING[@]}" | sed 's/, $//')"
    if confirm "Install the missing prerequisites now?"; then
      bootstrap
      BOOTSTRAPPED=1
    fi
  fi
fi

# --- 1. Flutter SDK check -------------------------------------------------
load_known_paths
if ! have flutter; then
  die "Flutter isn't installed (or isn't on your PATH yet).
     Install it automatically by re-running with 'deps':
       ./scripts/install.sh $PLATFORM deps
     or manually from https://docs.flutter.dev/get-started/install
     If you just installed it, open a new terminal window and try again."
fi
log "Flutter found: $(flutter_version)"

# On Linux, Flutter only looks for 'google-chrome'; point it at Chromium too.
if [ "$HOST_OS" = "Linux" ] && [ -z "${CHROME_EXECUTABLE:-}" ] && ! have google-chrome; then
  if chromium_bin="$(linux_chrome_path)"; then
    export CHROME_EXECUTABLE="$chromium_bin"
    log "Using browser: $CHROME_EXECUTABLE"
    persist_line "export CHROME_EXECUTABLE=\"$CHROME_EXECUTABLE\"" "the browser location"
  fi
fi

# --- 2. Enable the target platform ---------------------------------------
case "$PLATFORM" in
  macos) flutter config --enable-macos-desktop >/dev/null ;;
  linux) flutter config --enable-linux-desktop >/dev/null ;;
  web)   flutter config --enable-web >/dev/null ;;
esac
log "Platform enabled: $PLATFORM"

# On macOS, keep the build on the CocoaPods plugin path. `sqlite3_flutter_libs`
# (our SQLite dependency) does not ship a Swift Package Manager manifest, so if
# Flutter's SPM integration is enabled the macOS build prints an SPM warning and
# — in stricter contexts (Xcode / a future Flutter) — can fail resolving it.
# Disabling SPM and clearing any stale generated SPM package forces the
# CocoaPods fallback the project's macos/Podfile is set up for.
if [ "$PLATFORM" = "macos" ]; then
  flutter config --no-enable-swift-package-manager >/dev/null 2>&1 || true
  if [ -d macos/Flutter/ephemeral/Packages ]; then
    log "Clearing stale generated Swift Package Manager files for macOS..."
    rm -rf macos/Flutter/ephemeral/Packages
  fi
fi

# After installing things, show Flutter's own summary of the setup.
if [ "$BOOTSTRAPPED" = "1" ]; then
  log "Flutter's health check (flutter doctor). Items unrelated to $PLATFORM can be ignored:"
  flutter doctor || true
fi

# --- 3. Install dependencies ---------------------------------------------
log "Installing Dart/Flutter package dependencies..."
flutter pub get || die "Couldn't download the app's packages. Check your internet connection, then re-run."

if [ "$PLATFORM" = "web" ]; then
  # Regenerate the SQLite WASM worker + binary the web build needs. Idempotent.
  log "Setting up SQLite WASM assets for web..."
  dart run sqflite_common_ffi_web:setup || warn "sqflite web setup reported a non-zero status; existing web/ assets will be used."
fi

# --- 4. Build ------------------------------------------------------------
log "Building the app for $PLATFORM (this can take a few minutes on first run)..."
case "$PLATFORM" in
  macos) flutter build macos ;;
  linux) flutter build linux ;;
  web)   flutter build web ;;
esac || die "The build failed. The first error above explains why.
     To see what's missing, run:  ./scripts/install.sh $PLATFORM check"
log "Build complete."

# Point the user at the finished, standalone artifact so they can double-click
# it (desktop) or find the hostable bundle (web) without hunting through build/.
report_artifact() {
  case "$PLATFORM" in
    macos)
      local app
      app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
      if [ -n "${app:-}" ]; then
        log "Your app is ready: $PROJECT_ROOT/$app"
        log "Double-click it in Finder, or copy it to /Applications or your Desktop."
      fi
      ;;
    linux)
      # x64 or arm64, depending on this machine.
      local bundle
      bundle="$(find build/linux -maxdepth 3 -type d -path '*/release/bundle' 2>/dev/null | head -n 1)"
      if [ -n "$bundle" ] && [ -d "$bundle" ]; then
        log "Your app is ready: $PROJECT_ROOT/$bundle/spwrite"
        log "Run it directly, or copy the whole 'bundle' folder wherever you like."
      fi
      ;;
    web)
      if [ -d "build/web" ]; then
        log "Your hostable web bundle is ready: $PROJECT_ROOT/build/web"
      fi
      ;;
  esac
}
report_artifact

# --- 5. Launch -----------------------------------------------------------

# Headless Linux (no screen, e.g. Ubuntu Server): the app is built, but it
# can't open a window here. Offer a lightweight desktop + remote desktop
# server (XFCE + xrdp) so the user can open Spwrite from another computer.
if [ "$PLATFORM" = "linux" ] && [ "$HEADLESS" = "1" ]; then
  APP_BIN="$PROJECT_ROOT/$(find build/linux -maxdepth 3 -type d -path '*/release/bundle' 2>/dev/null | head -n 1)/spwrite"
  warn "This computer has no screen (no DISPLAY / WAYLAND_DISPLAY), so Spwrite can't open its window here."
  log  "The app built fine: $APP_BIN"
  detect_linux_pm
  if [ "$LINUX_PM" = "apt" ] && ! have xrdp; then
    if confirm "Install a lightweight desktop (XFCE) and a remote desktop server (xrdp) so you can open Spwrite from your own computer? (about 500 MB, needs your password)"; then
      as_root apt-get update
      as_root apt-get install -y xfce4 xfce4-terminal dbus-x11 xrdp \
        || die "Installing the remote desktop failed. Scroll up for details, then re-run."
      # xrdp starts this session for the user; XFCE is the desktop it opens.
      printf '%s\n' "startxfce4" >"$HOME/.xsession"
      as_root adduser xrdp ssl-cert >/dev/null 2>&1 || true
      as_root systemctl enable --now xrdp || warn "Couldn't start xrdp automatically. Run: sudo systemctl enable --now xrdp"
      if have ufw && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
        warn "The firewall (ufw) is on. Remote desktop uses port 3389."
        warn "Safest: don't open it, and use an SSH tunnel (below). Or allow it: sudo ufw allow 3389/tcp"
      fi
    fi
  fi
  if have xrdp; then
    log "Open Spwrite from your Mac or PC:"
    log "  1. On your computer, open an SSH tunnel (keeps remote desktop private):"
    log "       ssh -L 3389:localhost:3389 $(id -un)@<this-server-address>"
    log "  2. Open a Remote Desktop app (Windows App / Microsoft Remote Desktop on Mac,"
    log "     built-in Remote Desktop on Windows, Remmina on Linux) and connect to: localhost"
    log "  3. Log in with your server username and password. In the desktop, open a terminal and run:"
    log "       $APP_BIN"
  else
    log "Other ways to see the app:"
    log "  - Install a desktop on this machine (e.g. sudo apt install ubuntu-desktop-minimal), then reboot."
    log "  - Copy the folder $(dirname "$APP_BIN") to a Linux PC with a desktop and run 'spwrite' there."
    log "  - From a computer with an X server (XQuartz on Mac), run: ssh -X $(id -un)@<this-server-address>"
    log "    then: sudo apt install xauth (once), and run $APP_BIN"
  fi
  exit 0
fi

# Without Chrome, serve the web app and let the user open it in any browser.
# A screenless server always serves, since it can't open a browser itself.
WEB_DEVICE="chrome"
if [ "$PLATFORM" = "web" ]; then
  if [ "$HEADLESS" = "1" ]; then
    WEB_DEVICE="web-server"
  elif { [ "$HOST_OS" = "Darwin" ] && ! mac_chrome_path >/dev/null; } ||
     { [ "$HOST_OS" = "Linux" ] && ! linux_chrome_path >/dev/null; }; then
    WEB_DEVICE="web-server"
    log "Chrome wasn't found, so the app will be served for any browser you like."
  fi
fi

# Tells the user how to reach the web version, including from another computer.
web_hint() {
  [ "$PLATFORM" = "web" ] || return 0
  log "Once compiled, open http://localhost:$WEB_PORT"
  if [ "$HEADLESS" = "1" ] && [ "$WEB_HOST" = "localhost" ]; then
    log "This server has no screen. To open Spwrite from your own computer, run there:"
    log "    ssh -L $WEB_PORT:localhost:$WEB_PORT $(id -un)@<this-server-address>"
    log "  then browse to http://localhost:$WEB_PORT on your computer."
    log "  (Or start with WEB_HOST=0.0.0.0 to listen on the network -- trusted networks only, there's no login.)"
  elif [ "$WEB_HOST" != "localhost" ]; then
    warn "Listening on $WEB_HOST:$WEB_PORT. Anyone who can reach this address can open the app; there's no login."
  fi
}

run_cmd() {
  case "$PLATFORM" in
    web)   flutter run -d "$WEB_DEVICE" --web-hostname "$WEB_HOST" --web-port "$WEB_PORT" ;;
    macos) flutter run -d macos ;;
    linux) flutter run -d linux ;;
  esac
}

if [ "$MODE" = "background" ]; then
  LOG_FILE="$PROJECT_ROOT/spwrite-$PLATFORM.log"
  log "Launching $PLATFORM in the background. Logs: $LOG_FILE"
  # nohup + & detaches the process from this terminal session. Values are
  # passed through the environment so no quoting can break the inner command.
  PLATFORM="$PLATFORM" WEB_PORT="$WEB_PORT" WEB_HOST="$WEB_HOST" WEB_DEVICE="$WEB_DEVICE" \
    nohup bash -c "$(declare -f run_cmd); run_cmd" >"$LOG_FILE" 2>&1 &
  echo $! >"$PROJECT_ROOT/spwrite-$PLATFORM.pid"
  log "Started (PID $(cat "$PROJECT_ROOT/spwrite-$PLATFORM.pid")). Tail logs with: tail -f \"$LOG_FILE\""
  web_hint
else
  log "Launching $PLATFORM in this terminal (Ctrl+C to stop)..."
  web_hint
  run_cmd
fi
