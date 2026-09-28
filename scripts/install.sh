#!/usr/bin/env bash
#
# Spwrite installer for macOS, Linux, and Web.
#
# What it does:
#   1. Verifies the Flutter SDK is installed (and prints how to get it if not).
#   2. Enables the target platform in Flutter.
#   3. Installs all build/runtime dependencies (`flutter pub get`, plus the
#      SQLite WASM assets for web).
#   4. Builds and launches the app -- either immediately in the foreground
#      (terminal) or detached in the background.
#
# Usage:
#   ./scripts/install.sh [PLATFORM] [MODE]
#
#   PLATFORM : macos | linux | web        (default: web)
#   MODE     : now | background | deps    (default: now)
#
#   The special word `deps` (usable in either slot) first installs the system
#   prerequisites -- Flutter and the platform build tools -- using Homebrew on
#   macOS and the native package manager (apt / dnf / pacman, plus snap) on
#   Linux, then continues with the normal build + run. Every privileged step
#   (installing Homebrew, using sudo, or a package manager) asks for your
#   confirmation first, and can be skipped.
#
# Examples:
#   ./scripts/install.sh web now          # build + run web in this terminal
#   ./scripts/install.sh macos background  # build + run macOS detached
#   ./scripts/install.sh linux now
#   ./scripts/install.sh macos deps        # install prerequisites, then run
#   ./scripts/install.sh deps              # just install prerequisites for web
#
set -euo pipefail

# `deps` may appear in either positional slot; pull it out into WANT_DEPS and
# leave PLATFORM / MODE with their normal values.
WANT_DEPS=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "deps" ]; then
    WANT_DEPS=1
  else
    ARGS+=("$arg")
  fi
done

PLATFORM="${ARGS[0]:-web}"
MODE="${ARGS[1]:-now}"
WEB_PORT="${WEB_PORT:-8080}"
# Set ASSUME_YES=1 to answer "yes" to every prompt (non-interactive installs).
ASSUME_YES="${ASSUME_YES:-0}"

# Resolve the project root (the parent of this scripts/ directory) so the
# installer works no matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

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

# --- Dependency bootstrap -------------------------------------------------
# Installs Flutter and the platform build tools. Everything privileged is
# gated behind confirm(), so the user always opts in before an install runs.

# macOS: Homebrew for everything. Installs Homebrew itself if missing, then
# Flutter (cask) and the Xcode command-line tools. Full Xcode (needed only for
# a signed .app / iOS) can't be installed unattended, so we detect + instruct.
bootstrap_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    if confirm "Homebrew is not installed. Install it now (from brew.sh)?"; then
      log "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Make brew available on this shell for the rest of the run (Apple
      # Silicon installs to /opt/homebrew, Intel to /usr/local).
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    else
      warn "Skipping Homebrew; cannot auto-install Flutter without it."
      return
    fi
  fi
  log "Homebrew found: $(brew --version | head -n 1)"

  # Xcode command-line tools (clang, git, make) — the minimum toolchain.
  if ! xcode-select -p >/dev/null 2>&1; then
    if confirm "Install the Xcode command-line tools (opens Apple's installer)?"; then
      xcode-select --install || warn "xcode-select reported a non-zero status; it may already be installing."
      log "Finish the Apple command-line-tools installer, then re-run if needed."
    fi
  else
    log "Xcode command-line tools present: $(xcode-select -p)"
  fi

  # Flutter via Homebrew cask.
  if ! command -v flutter >/dev/null 2>&1; then
    if confirm "Install Flutter with 'brew install --cask flutter'?"; then
      log "Installing Flutter (this downloads the SDK; can take a while)..."
      brew install --cask flutter
    fi
  fi

  # Only building a macOS desktop app needs full Xcode; the web build does not.
  if [ "$PLATFORM" = "macos" ]; then
    ensure_full_xcode
  fi
}

# Make the full Xcode toolchain usable for a macOS build.
#
# The common trap: Xcode.app is installed under /Applications, but the active
# developer directory still points at /Library/Developer/CommandLineTools, so
# `xcodebuild` (and Flutter) report "Xcode is required" even though it is right
# there. Here we detect that case and, with the user's consent, run the three
# `sudo` steps that fix it (switch, first-launch, license). We also make sure
# CocoaPods is present, which Flutter needs to build macOS/iOS plugins.
ensure_full_xcode() {
  # If xcodebuild already works, the toolchain is good — just check CocoaPods.
  if xcodebuild -version >/dev/null 2>&1; then
    log "Full Xcode is active: $(xcodebuild -version | head -n 1)"
    ensure_cocoapods
    return
  fi

  # Find an installed Xcode app to switch to.
  local xcode_app=""
  if [ -d "/Applications/Xcode.app" ]; then
    xcode_app="/Applications/Xcode.app"
  else
    xcode_app="$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' 2>/dev/null | head -n 1)"
  fi

  if [ -z "$xcode_app" ]; then
    # No Xcode.app at all — it genuinely has to be installed first.
    warn "Full Xcode is required to build a macOS desktop app but was not found."
    warn "Install it from the Mac App Store (search 'Xcode'), then re-run:"
    warn "  ./scripts/install.sh macos deps"
    warn "The command-line tools alone are enough for the web build."
    return
  fi

  # Xcode.app exists but the toolchain still points at the CLT. Offer to fix.
  local active
  active="$(xcode-select -p 2>/dev/null || true)"
  warn "Xcode is installed at $xcode_app, but the active developer directory is:"
  warn "  ${active:-<none>}"
  warn "macOS builds need the toolchain pointed at the full Xcode instead."
  log  "The fix runs three commands as administrator (you'll be asked for your password):"
  log  "  sudo xcode-select --switch $xcode_app/Contents/Developer"
  log  "  sudo xcodebuild -runFirstLaunch"
  log  "  sudo xcodebuild -license accept"

  if confirm "Point the toolchain at full Xcode now (runs the sudo commands above)?"; then
    sudo xcode-select --switch "$xcode_app/Contents/Developer"
    # First-launch installs additional components; license accept is required
    # before any build will run. Neither is fatal to retry, so warn on failure.
    sudo xcodebuild -runFirstLaunch || warn "xcodebuild -runFirstLaunch reported a non-zero status."
    sudo xcodebuild -license accept || warn "xcodebuild -license accept reported a non-zero status."
    if xcodebuild -version >/dev/null 2>&1; then
      log "Full Xcode is now active: $(xcodebuild -version | head -n 1)"
    else
      warn "Xcode still isn't active. Open Xcode.app once to finish setup, then re-run."
    fi
  else
    warn "Skipped. Run the three commands above yourself, then re-run the installer."
  fi

  ensure_cocoapods
}

# Ensure CocoaPods is available (Flutter needs it to build macOS/iOS plugins).
# Prefer Homebrew since it needs no sudo and we already require brew on macOS.
ensure_cocoapods() {
  if command -v pod >/dev/null 2>&1; then
    log "CocoaPods present: $(pod --version 2>/dev/null)"
    return
  fi
  if confirm "CocoaPods is needed for macOS plugins. Install it with 'brew install cocoapods'?"; then
    brew install cocoapods || warn "brew install cocoapods reported a non-zero status."
  else
    warn "Skipped CocoaPods. If a macOS build fails on plugins, run: brew install cocoapods"
  fi
}

# Linux: use whichever native package manager is present for the GTK/build
# deps, and prefer snap for Flutter (the maintained Linux channel). If neither
# a package manager nor snap is available, fall back to instructions.
bootstrap_linux() {
  local install_cmd="" update_cmd="" pkgs=""
  if command -v apt-get >/dev/null 2>&1; then
    update_cmd="sudo apt-get update"
    install_cmd="sudo apt-get install -y"
    pkgs="curl git unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev"
  elif command -v dnf >/dev/null 2>&1; then
    install_cmd="sudo dnf install -y"
    pkgs="curl git unzip xz zip clang cmake ninja-build pkgconf-pkg-config gtk3-devel"
  elif command -v pacman >/dev/null 2>&1; then
    install_cmd="sudo pacman -S --needed --noconfirm"
    pkgs="curl git unzip xz zip clang cmake ninja pkgconf gtk3"
  else
    warn "No supported package manager (apt/dnf/pacman) found."
    warn "Install the Flutter Linux prerequisites manually:"
    warn "  https://docs.flutter.dev/get-started/install/linux"
    return
  fi

  if confirm "Install Linux build tools with: $install_cmd $pkgs ?"; then
    [ -n "$update_cmd" ] && $update_cmd
    # shellcheck disable=SC2086
    $install_cmd $pkgs
  else
    warn "Skipping build-tool install."
  fi

  # Flutter via snap when available; otherwise point at the SDK archive.
  if ! command -v flutter >/dev/null 2>&1; then
    if command -v snap >/dev/null 2>&1; then
      if confirm "Install Flutter with 'sudo snap install flutter --classic'?"; then
        sudo snap install flutter --classic
      fi
    else
      warn "snap is not available; install Flutter manually from the SDK archive:"
      warn "  https://docs.flutter.dev/get-started/install/linux"
    fi
  fi
}

if [ "$WANT_DEPS" = "1" ]; then
  log "Installing prerequisites (deps mode)..."
  case "$(uname -s)" in
    Darwin) bootstrap_macos ;;
    Linux)  bootstrap_linux ;;
    *)      warn "Automatic dependency install is not supported on $(uname -s). Install Flutter from https://docs.flutter.dev/get-started/install" ;;
  esac
fi

# --- 1. Flutter SDK check -------------------------------------------------
if ! command -v flutter >/dev/null 2>&1; then
  # If the user did not ask for deps, offer the bootstrap now rather than just
  # failing, so a first-time user has a one-word path forward.
  if [ "$WANT_DEPS" != "1" ] && confirm "Flutter is not installed. Install prerequisites automatically now?"; then
    case "$(uname -s)" in
      Darwin) bootstrap_macos ;;
      Linux)  bootstrap_linux ;;
    esac
  fi
fi
if ! command -v flutter >/dev/null 2>&1; then
  die "Flutter SDK not found on PATH.
     Install it automatically by re-running with 'deps', e.g.:
       ./scripts/install.sh $PLATFORM deps
     or manually from https://docs.flutter.dev/get-started/install
     (macOS: 'brew install --cask flutter')."
fi
log "Flutter found: $(flutter --version | head -n 1)"

# --- 2. Enable the target platform ---------------------------------------
case "$PLATFORM" in
  macos) flutter config --enable-macos-desktop >/dev/null ;;
  linux) flutter config --enable-linux-desktop >/dev/null ;;
  web)   flutter config --enable-web >/dev/null ;;
  *)     die "Unknown platform '$PLATFORM'. Use: macos | linux | web" ;;
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

# --- 3. Install dependencies ---------------------------------------------
log "Installing Dart/Flutter package dependencies..."
flutter pub get

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
esac
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
      local bundle="build/linux/x64/release/bundle"
      if [ -d "$bundle" ]; then
        log "Your app is ready: $PROJECT_ROOT/$bundle/writing_app"
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
run_cmd() {
  case "$PLATFORM" in
    web)   flutter run -d chrome --web-port "$WEB_PORT" ;;
    macos) flutter run -d macos ;;
    linux) flutter run -d linux ;;
  esac
}

if [ "$MODE" = "background" ]; then
  LOG_FILE="$PROJECT_ROOT/spwrite-$PLATFORM.log"
  log "Launching $PLATFORM in the background. Logs: $LOG_FILE"
  # nohup + & detaches the process from this terminal session.
  nohup bash -c "$(declare -f run_cmd); PLATFORM='$PLATFORM' WEB_PORT='$WEB_PORT' run_cmd" >"$LOG_FILE" 2>&1 &
  echo $! > "$PROJECT_ROOT/spwrite-$PLATFORM.pid"
  log "Started (PID $(cat "$PROJECT_ROOT/spwrite-$PLATFORM.pid")). Tail logs with: tail -f \"$LOG_FILE\""
  [ "$PLATFORM" = "web" ] && log "Once compiled, open http://localhost:$WEB_PORT"
else
  log "Launching $PLATFORM in this terminal (Ctrl+C to stop)..."
  [ "$PLATFORM" = "web" ] && log "Once compiled, open http://localhost:$WEB_PORT"
  run_cmd
fi
