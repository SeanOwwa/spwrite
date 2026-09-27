# Spwrite

Spwrite is a cross-platform writing app for organizing your work into
**projects**, **folders**, and **documents**, with a distraction-free
WYSIWYG editor. Everything is stored locally with SQLite, so your writing
lives on your own machine (or in the browser's storage on web) and stays
available offline.

## Features

- **Project dashboard** — create, rename, delete, and open projects from a
  single landing screen.
- **Folders and documents** — organize each project into an expandable folder
  tree with root-level documents, and reorder them by recent activity.
- **Rich text editor** — a `flutter_quill` WYSIWYG editor with bold, italic,
  headings, ordered/unordered lists, and links, stored as Markdown.
- **Autosave** — edits are debounced and persisted automatically.
- **Dark theme** — a single dark palette applied across every surface.
- **Local persistence** — native SQLite on desktop/mobile and IndexedDB-backed
  WASM SQLite on the web.

## Platforms

macOS, Linux, Windows, Web, iOS, and Android. The install scripts below cover
macOS, Linux, Windows, and Web.

## Developers

- **Seanless** — product direction, requirements, and review.
- **Kiro** — implementation, tests, and tooling.

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.22 or newer
  (Dart 3.4+). The install scripts check for this and tell you how to get it if
  it is missing.
- For **web**: Google Chrome.
- For **desktop**: the platform toolchain (Xcode on macOS, the C/C++ build
  tools + GTK on Linux, Visual Studio with the "Desktop development with C++"
  workload on Windows).

## Installation

The repo ships with one-shot install scripts under `scripts/`. Each script
**installs all build/runtime dependencies** (`flutter pub get`, plus the SQLite
WASM assets for web) and then **builds and launches** the app.

Every script takes two optional arguments:

| Argument | Values | Default | Meaning |
| --- | --- | --- | --- |
| `PLATFORM` | `web`, `macos`, `linux`, `windows` | `web` | which target to install/run |
| `MODE` | `now`, `background` | `now` | run in this terminal, or detached in the background |

- **`now`** runs the app in the **foreground of the current terminal** (press
  `Ctrl+C` to stop). Good for a quick launch where you want to see the output.
- **`background`** launches the app **detached from the terminal**. Output is
  written to `writepad-<platform>.log` and the process id to
  `writepad-<platform>.pid` in the project root, so you can keep using the same
  shell.

### macOS / Linux / Web

```bash
# From the project root:
chmod +x scripts/install.sh          # first time only

# Web, in this terminal (default):
./scripts/install.sh
# equivalent to: ./scripts/install.sh web now

# Web, in the background:
./scripts/install.sh web background

# macOS desktop, foreground / background:
./scripts/install.sh macos now
./scripts/install.sh macos background

# Linux desktop:
./scripts/install.sh linux now
```

For web you can override the port: `WEB_PORT=9000 ./scripts/install.sh web now`,
then open `http://localhost:9000`.

### Windows

Run from **PowerShell** in the project root:

```powershell
# Web, in this terminal (default):
.\scripts\install.ps1
# equivalent to: .\scripts\install.ps1 web now

# Web, in the background:
.\scripts\install.ps1 web background

# Windows desktop, foreground / background:
.\scripts\install.ps1 windows now
.\scripts\install.ps1 windows background
```

Override the web port with `-WebPort`:
`.\scripts\install.ps1 web now -WebPort 9000`.

> If PowerShell blocks the script, allow it for the current session with:
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

### Stopping a background run

- **macOS / Linux:** `kill $(cat writepad-<platform>.pid)`
- **Windows (PowerShell):** `Stop-Process -Id (Get-Content writepad-<platform>.pid)`

## Manual setup (without the scripts)

```bash
flutter pub get
# Web only — generate the SQLite WASM worker + binary:
dart run sqflite_common_ffi_web:setup
# Run:
flutter run -d chrome        # web
flutter run -d macos         # macOS
flutter run -d linux         # Linux
flutter run -d windows       # Windows
```

## Running the tests

```bash
flutter analyze
flutter test
```
