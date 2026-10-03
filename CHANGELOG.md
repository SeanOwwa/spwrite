# Changelog

All notable changes to Spwrite are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.3.5] (Beta) - Unreleased

### Fixed

- **Esc didn't leave focus mode while typing.** The editor's own Esc action
  took priority, so Esc only worked when the cursor wasn't in the page. Esc now
  leaves focus mode wherever the cursor is.

## [1.3.4] (Beta) - Unreleased

### Added

- **Keyboard shortcuts like a word processor** (Cmd on Mac, Ctrl on Windows
  and Linux): bold, italic, link, headings 1–3 and normal text, numbered and
  bulleted lists (Shift+7 / Shift+8), redo (Shift+Z), save now (S), focus mode
  (Shift+F), hide the sidebar (Backslash), AI panel (Shift+A), and a shortcut
  list (/). Toolbar tooltips show each button's shortcut.
- **Focus mode.** Hides the sidebar, title, toolbar and panels, leaving only
  the page and a small word-count chip. Esc leaves it.
- **Words this session.** The word count also shows how many words were added
  since the document was opened (e.g. "1,240 words · +312").
- **Em dash.** Typing three hyphens (`---`) turns into "—".
- **More room at the bottom of the page**, so the last lines can be scrolled up
  to eye level.
- **Built-in User Guide and Developer Guide projects.** Always listed first on
  the dashboard, read-only, and cannot be deleted or renamed. They update
  automatically when a new version changes them. The User Guide covers every
  feature; the Developer Guide covers the app's layers, SOLID principles, the
  database, building, testing and conventions.
- **Guides switch** next to New project hides or shows the two guides. The
  choice is remembered.

### Changed

- **The AI assistant shows "Coming soon".** Nothing can be downloaded and no
  background indexing runs while it is being stabilised on the `ai_feature`
  branch.

### Fixed

- **Italic text came back with underscores at both ends** after autosave and
  reopening, when the selection included a space or covered part of a word.
  Italic and bold now save correctly, and documents already affected are
  repaired automatically when opened.
- **The last few seconds of typing could be lost or saved to the wrong
  document** when switching or creating a document, closing the project, or
  quitting within the 2-second autosave window. Pending edits are now saved
  first.
- **Bullets and numbers sat above the text in lists.** The markers now use the
  same font, size and double line spacing as the text, so they line up.
- **Some shortcuts added formatting that vanished after saving** (underline,
  strikethrough, inline code, quote, checklist, indent, image). These are now
  turned off.

## [1.2.3] (Beta) - Unreleased

### Fixed

- **SpwriteBot crashed or errored on Windows while downloading or chatting**
  ("A AiAssistantState was used after being disposed"). A model download kept
  running after its project was closed, then tried to update the panel that no
  longer existed. Late updates from downloads, replies and indexing are now
  ignored once the project closes.
- **Repeated model downloads clashed.** Reopening a project during a download
  started a second transfer into the same temporary file, so both failed their
  checksum. Only one download per model runs now; a reopened panel joins it and
  shows its progress.
- **The Windows app didn't start after moving its folder to another PC**
  ("MSVCP140.dll / VCRUNTIME140.dll was not found"). The build now copies the
  Microsoft Visual C++ runtime DLLs into the `Release` folder, so the folder
  runs on PCs without the VC++ Redistributable installed.
- **The Windows installer now installs the app** to
  `%LOCALAPPDATA%\Programs\Spwrite` and adds Desktop and Start menu shortcuts
  (after asking). Copying the `Release` folder by hand to a OneDrive-synced
  Desktop could leave the app silently refusing to start. It also finds the
  ARM64 build (`build\windows\arm64\...`).
- **Model download "failed integrity check" (seen on Linux).** A transfer that
  ends early, or a proxy or sign-in page answering instead of Hugging Face,
  produced a checksum error with no hint why. Downloads are now checked for the
  full size and for a real GGUF file before the checksum, with a plain message
  for each case, and a failed transfer is retried once from scratch
  automatically.
- **Installing on a Linux server without a screen** (e.g. Ubuntu Server over
  SSH) failed with "cannot open display" and "Error waiting for a debug
  connection". The installer now detects a missing graphical session, still
  builds the app, and offers (apt) to install a lightweight remote desktop
  (XFCE + xrdp). It then prints how to connect through an SSH tunnel and
  where the `spwrite` binary is, instead of trying to open a window. The
  Chromium offer is skipped.
- New `WEB_HOST` setting (default `localhost`) for the web version's listening
  address, with a warning when it's opened to the network.
- **Linux build failed in the AI runtime** ("building assets for package:
  fllama failed", "Target build_hooks failed"). The fllama build compiles
  llama.cpp with `aarch64-linux-gnu-gcc`/`g++` (or the x86_64 versions), which
  come from GCC, but the installer only installed clang. It now also installs
  `build-essential` (apt), `gcc gcc-c++` (dnf, zypper) or `gcc` (pacman).
- The installer now reports the Linux app on ARM (`build/linux/arm64/...`) and
  uses the correct binary name (`spwrite`).

### Known limitations

- On Windows in a virtual machine, the app can still close while SpwriteBot
  generates a reply. The AI engine depends on the CPU and graphics features the
  VM exposes, and on enough memory (8 GB recommended). Writing, editing and
  keyword search are unaffected.

## [1.2.2] (Beta) - Unreleased

### Added

- **Choose where exports are saved.** On desktop, exporting to Word opens the
  native Save As dialog with the project name as the suggested file name.
  Cancelling closes the Save As dialog without saving or showing an error, and
  the export window stays open. A `.docx` extension is added if you remove it.
- **Remembered export folder.** The folder you last saved to is remembered
  across launches and pre-selected in the Save As dialog. The export window
  shows it as "Save to: <folder>" with a "Change…" button to set it up front.
  If that folder no longer exists, Spwrite falls back to Downloads (or
  Documents).
- **Show in folder.** The confirmation message shows the full path of the
  saved file and offers "Show in folder" (Finder on macOS, Explorer on
  Windows, the default file manager on Linux).

### Changed

- **macOS sandbox entitlement.** `com.apple.security.files.user-selected` is
  now `read-write` instead of `read-only` (Debug/Profile and Release), so the
  app can write to the location you pick. The cover photo picker works as
  before. On macOS every export goes through the Save As dialog, because the
  sandbox doesn't let the app write silently to a folder remembered from an
  earlier launch.
- **Database schema v7 → v8.** Adds a small `app_settings` key/value table
  (used for the remembered export folder). The upgrade only creates the table;
  existing projects, documents, characters, and conversations are untouched.

## [1.2.1] (Beta) - Unreleased

Covers everything since commit `548d0a4` ("Fix Mac Errors").

### Added

- **On-device AI Panel ("SpwriteBot").** A writing assistant beside the editor,
  opened from the AI icon in the editor toolbar. It shares the right-hand slot
  with the Character Panel.
  - Runs **Qwen2.5-1.5B-Instruct** (Q4_K_M GGUF, Apache-2.0) in-process through
    the `fllama` llama.cpp binding. No account, API key, telemetry, or cost.
  - One-time model download (~0.9 GB) with progress, stall detection, retry,
    and SHA-256 verification before the file is used. Works offline after that.
  - Streaming replies with a typing indicator and a stop button.
  - Answers are grounded in the open project's documents and characters, with
    a "Sources" hint under each answer.
  - Non-blocking offline banner.
  - "Coming soon (VIP)" placeholders for web research and image generation.
    They are disabled and make no network requests.
  - Conversations are saved per project and come back when you reopen it.
  - **New chat** button that clears the conversation, including the saved
    history, after a confirmation.
- **Semantic search across the whole project.**
  - Documents and characters are split into short passages, embedded with
    **bge-small-en-v1.5** (Q8_0 GGUF, Apache-2.0, ~37 MB, a second one-time
    download), and stored in a local vector index.
  - Questions are matched by meaning, not just shared words.
  - Fits the retrieved passages into the model's context budget and skips
    passages below a relevance threshold.
  - Background indexing with a status strip in the AI Panel (download, X of Y
    progress, ready, error). Only changed passages are re-embedded. Interrupted
    builds resume, and removed or renamed sources are tracked.
  - Falls back to keyword search, then plain chat, whenever semantic search
    isn't available.
  - The assistant tells you when it is working from a limited set of passages
    rather than claiming to have read the whole book.
- **Project cover photos.**
  - Add a cover when creating a project, or later through the new
    Create / Edit project dialog.
  - Covers are stored at exactly **1600 × 2560 px (1.6:1)**. Other shapes are
    center-cropped and resized, EXIF rotation is applied, and the result is
    saved as JPEG.
  - Accepts PNG, JPG, and WebP. Unreadable or oversized files show a friendly
    error.
  - Covers appear on dashboard cards and in the sidebar header. Projects
    without a cover keep the colourful initial badge.
- **Installer `check` mode** (`./scripts/install.sh <platform> check`,
  `.\scripts\install.ps1 <platform> check`). It reports what's installed and
  what's missing without changing anything.
- Keyboard shortcut **Cmd+N / Ctrl+N** to create a project from the dashboard.
- `lib/app_info.dart` with the displayed version label (`Beta 1.2.1`).
- A small version label ("Beta 1.2.1") next to the Projects title on the
  dashboard.
- `CHANGELOG.md` (this file).

### Changed

- **UI refresh for macOS, Windows, and Linux.** Keeps the navy and dark-cyan
  theme.
  - New spacing and motion tokens, and all colours now come from `AppPalette`.
  - Visible keyboard focus rings, hover and press feedback, always-visible
    desktop scrollbars, tooltips, and larger click targets.
  - Responsive dashboard grid of portrait cover cards.
  - Editor writing column capped at a comfortable width, and a reorganised
    toolbar.
  - Shared header style for the Character and AI panels.
  - Restyled chat bubbles.
- Dashboard renaming now happens in the Edit project dialog instead of the
  inline name field.
- **Install scripts now set up everything from scratch** on each OS. Every
  system change asks first unless `ASSUME_YES=1` / `-AssumeYes` is set.
  - **macOS:** Homebrew, Xcode Command Line Tools, Git, Flutter, full Xcode
    setup (license, first launch), and CocoaPods. Chrome is optional.
  - **Linux:** detects apt, dnf, pacman, or zypper and installs the toolchain,
    GTK 3, SQLite, and other build packages. Flutter comes from snap or the
    official stable git checkout. Chromium is optional.
  - **Windows:** uses winget, with Chocolatey as a fallback. Installs Git,
    Flutter (official stable checkout added to the user PATH), and Visual
    Studio 2022 Build Tools with the C++ workload. Checks Developer Mode.
    Chrome is optional, and Edge is used if Chrome is missing.
  - All OSes: if no Chrome is found, the web version is served so any browser
    can open it.
- **Word export keeps formatting.** Headings, bullet and numbered lists, and
  bold, italic, underline, and strikethrough now carry over to the `.docx`
  file.
- README: documents the AI assistant, semantic search, offline and privacy
  guarantees, and the new installer options.
- `SURVEY_QUESTION.md`: updated the writer survey for the AI features.
- Version set to **Beta 1.2.1** (`1.2.1+3`). The previous committed
  `pubspec.yaml` had `1.0.0+1`.
- `pubspec.lock` is now tracked in git (removed from `.gitignore`) for
  reproducible builds. `.gitignore` also ignores `semantic-review/`, `*.gguf`
  model files, and `coverage/`.

### Removed

- **Android and iOS targets.** Spwrite now targets macOS, Windows, Linux, and
  web only. The `android/` and `ios/` folders and the mobile launcher-icon
  settings are gone.
- The mobile-only `sqflite` dependency. Desktop uses `sqflite_common_ffi` and
  web uses `sqflite_common_ffi_web`.
- The unused `assets/images/spwrite_logo.jpeg` (the PNG logo is used).
- An old audit note (`semantic-review/`) and the IDE file `spwrite.iml`.

### Fixed

- **Editor lost line breaks.** Pressing Enter for blank lines between
  paragraphs, or a trailing blank line, disappeared after the document was
  saved and reopened. The Tab indent could also turn a line into a code block.
  Markdown collapses blank lines and treats a 4+ space indent as code, so the
  codec now stores those lines with a no-break-space placeholder and restores
  them on load. Documents saved before this fix already lost their blank
  lines, and those can't be recovered.
- AI replies failed with "request exceeds the available context size (512
  tokens)". fllama splits its context window across 4 parallel slots, so the
  engine now asks for 4 × the per-request window.
- The embedding model download returned **HTTP 401**. The catalog entry still
  had a placeholder URL. It now points at the published CompendiumLabs GGUF
  with its pinned size and SHA-256.
- Embeddings always reported "unsupported". A new `dart:ffi` binding to the
  llama.cpp C API bundled in `fllama` (running on a background isolate) now
  produces real embeddings.
- Garbage or very short files picked as a cover crashed format detection. They
  now show the friendly "not a supported image" error.

### Data and storage

- SQLite schema **v4 → v7**. All migrations are additive and idempotent, and
  existing data is untouched.
  - v5: `ai_conversations` (saved chat history per project).
  - v6: `ai_chunk_embeddings` (vector index) and `ai_index_state` (resume
    markers).
  - v7: `projects.cover_image` (nullable BLOB).

### Dependencies

- Added `fllama` (git, pinned to `f624e4bf`, GPL-2.0). It is copyleft, so
  Spwrite's own distribution must stay GPL-compatible while it's linked.
- Added `http 1.6.0`, `crypto 3.0.7`, `ffi 2.2.0`, `image 4.3.0`.
- Added dev dependency `fake_async 1.3.3`.

### Platform

- macOS: added the `com.apple.security.network.client` entitlement (Debug and
  Release) for the one-time model downloads. The app stays sandboxed.

### Known limitations

- Linux and Windows builds, and both of those installer paths, were not run on
  real machines for this release.
- The macOS cover file picker hasn't been tried by hand in the sandboxed app.
- If indexing hits an error during a session, it retries on the next launch.
- The llama.cpp struct mirrors must be checked again whenever `fllama` is
  updated.
