# Spwrite

**Beta 1.2.3** · macOS, Windows, Linux, and web

A calm, distraction-free writing app for your own computer. Organize your work
into **projects**, **folders**, and **documents**, and write in a clean editor
that looks like a manuscript. Everything is saved on your machine (or in your
browser on the web), so your writing is always with you and works offline.

Spwrite runs as a desktop app on **macOS, Windows, and Linux**, or in your web
browser. There are no phone or tablet versions.

## What it looks like

- **Serif text, double-spaced.** The editor uses a classic serif typeface with
  2.0 (double) line spacing — the same standard as a Google Docs manuscript —
  so your drafts are easy on the eyes and easy to mark up.
- **Live word count.** A running word count sits in the upper-right corner of
  the document, updating as you type.
- **Deep navy theme.** A dark, navy-blue workspace with dark-cyan highlights
  and a soft gradient backdrop, designed to be gentle for long writing
  sessions.
- **Refreshed desktop interface.** Your projects sit in a responsive grid of
  portrait book-cover cards. Clear focus rings, hover feedback, tooltips, and
  roomy click targets make it comfortable with a mouse or keyboard, and the
  writing column stays at a comfortable reading width. The current version
  (e.g. "Beta 1.2.3") is shown quietly next to the Projects title.

## What you can do

- Keep separate **projects** for different books, articles, or clients.
- **Cover photos.** Give each project a book cover when you create it or later
  from Edit project. Covers are saved at 1600 × 2560 px (a 1.6:1 portrait
  shape); other shapes are centered and cropped to fit. Projects without a
  cover show a colorful initial badge instead.
- Sort each project into **folders** and **documents**.
- **Drag to organize.** Grab the handle on the left of any row to reorder it.
  Folders and loose documents share one list, so a document can sit above,
  below, or between folders. Drag a document onto a folder to move it in, or
  drag it back out to the top level — and move documents from one folder to
  another the same way.
- **Tidy controls.** Rename and delete buttons stay hidden until you long-press
  a folder or document, so the sidebar stays clean while you write.
- Format as you write — bold, italic, headings, lists, and links.
- **Tab to indent.** Pressing Tab drops a clean 10-space indent wherever your
  cursor is.
- **Your spacing stays put.** Blank lines you add with Enter, including one at
  the end of a document, are kept exactly as you left them when you reopen it.
- **Export to Word.** Send any selection of documents to a single `.docx` file
  from the export icon in the editor toolbar. Each document's title becomes a
  heading and its text the body, with every document starting on a new page.
  On desktop you pick where the file goes in the usual Save As dialog. The
  export window shows the folder it will start in ("Save to"), with a
  "Change…" button to set it ahead of time. Spwrite remembers the last folder
  you used, and after saving it shows the full path with a "Show in folder"
  button. On the web the file downloads through your browser as before.
- **Character Panel.** Keep your cast close while you write. Open it from the
  people icon on the right of the editor toolbar to see a scrollable list of
  your characters. Each one has a name, role, free-form details, and a portrait
  image. The sidebar shows a short preview of the details; tap "See more" to
  read the full details right there, or open one to edit it on its own screen.
- **Autosave with a save indicator.** Your work saves itself as you go; there
  is no Save button to remember. A small status pill in the top-left of the
  editor toolbar shows exactly where things stand — "Saving…" the moment you
  type, then "Saved" once your text is safely on disk — so you always know your
  writing is captured.
- **AI Panel.** A writing assistant that lives beside your work. Open it from
  the AI icon on the right of the editor toolbar to chat about your draft —
  brainstorm, rephrase, continue a passage, or summarize. It can also search
  your own project material — your documents and characters — and answer
  grounded in what you actually wrote, showing which document or character it
  drew from. It can search a whole project by **meaning**, not just matching
  words, so it can find the right passage across every chapter and book in a
  long manuscript. Tap **New chat** to start a fresh conversation (it asks
  first, then clears the saved history for that project). It sits in the same
  right-hand slot as the Character Panel, so opening one tucks the other away
  to keep your writing room wide. See "Your on-device AI assistant" below for
  how it stays private and offline.

---

## Your on-device AI assistant

Spwrite's AI Panel runs a small language model **on your own computer**. There
is no account, no API key, no telemetry, and no per-use cost — and your writing
never leaves your device.

- **A one-time download, then fully offline.** The first time you use the
  assistant, Spwrite downloads the model file once — the only moment the
  internet is needed. It's cached on your machine and its integrity is verified
  before it's used, so a half-finished or corrupted download is never loaded as
  if it were complete. After that, chatting and searching your project material
  work with no connection at all. The panel tells you the approximate size up
  front and shows progress while it downloads; if you're offline it explains
  that the one-time download needs a connection and leaves the rest of the app
  fully usable in the meantime.
- **Free and open source.** The assistant uses an openly licensed small local
  model — **Qwen2.5-1.5B-Instruct** (a ~0.9 GB Q4_K_M GGUF), released under the
  **Apache-2.0** license — running through an open-source, on-device runtime.
  Nothing you write is sent anywhere, there's no sign-in, and there's no cost
  to use it.
- **Grounded in your own material, offline.** When you ask about your story,
  the assistant searches the Active Project's documents and characters on your
  machine and answers from that text, noting its sources. This search is scoped
  to the project you're in and never touches other projects or the internet.
- **Honest about connectivity.** If you're offline, the panel shows a quiet,
  non-blocking note that you're not connected — chat and project search keep
  working regardless.

### Semantic search across your whole project

Long manuscripts (hundreds of thousands of words across many chapters and
books) are far bigger than a local model can read at once. So the assistant
splits your project's documents and characters into short passages, turns each
into a numeric "meaning" fingerprint (an embedding), and keeps them in a small
index on your machine. When you ask a question, it pulls in only the handful of
passages closest in meaning, even if you worded the question differently from
how you wrote the text.

- **A second one-time download.** Semantic search uses its own small embedding
  model, **bge-small-en-v1.5** (GGUF, **Apache-2.0**, about 37 MB). It comes
  from a fixed, published download address, and the panel shows its size and
  progress, verifies it, and caches it. After that, indexing and searching work
  fully offline. The embeddings run on your computer through the same
  llama.cpp engine as the chat model.
- **Indexed in the background.** A slim strip in the AI Panel shows indexing
  progress. Writing, scrolling, and saving are never blocked, and after the
  first pass only documents you actually change are re-indexed.
- **Everything stays on your device.** Chunking, embedding, the index (stored
  in the app's local SQLite database), and search all run on your computer,
  scoped to the project you're in. No passage, query, or embedding is ever sent
  anywhere, and there's no account, API key, or cost.
- **Never in the way.** Until the embedding model is ready, or while the index
  is still building, the assistant falls back to keyword search over your
  project (or plain chat), exactly as before.
- **Honest about big-picture questions.** It's best at pinpoint and continuity
  lookups ("what colour are Mara's eyes?"). For whole-book questions it tells
  you it's working from a limited set of passages rather than claiming to have
  read everything.

### Coming soon

Two internet-powered abilities are shown in the panel as **"Coming soon"**
and are **disabled** in this release:

- **Web research** — searching the internet for historical and topic material.
- **AI image generation** — creating images from a prompt.

These controls appear dimmed with a badge and, if you tap them, simply explain
that they're a future feature. The shipping app makes **no** network request for
either of them — the only time Spwrite uses the network for AI is the one-time
model downloads described above.

### Where it runs

The assistant targets the desktop apps first — **macOS, Windows, and Linux**.
On macOS, the one-time model download uses the app's network client entitlement;
the app stays sandboxed otherwise.

---

## Getting started

You do not need to be technical to install Spwrite. Follow the section for your
computer below. The first time you run it, the installer downloads what it needs
and builds the app — this can take a few minutes. After that it is quick.

### Before you begin (one-time)

Spwrite is built with a free tool called **Flutter**, plus a few developer
tools your computer needs to build apps. You don't have to set these up by
hand: the installer checks for everything, tells you what's missing, and
offers to install it. It asks before each install, so nothing changes without
your say-so. (Prefer to do it yourself? Follow the
[Flutter install guide](https://docs.flutter.dev/get-started/install).)

To see what's already installed without changing anything, run:

```bash
./scripts/install.sh macos check        # Mac (or: web check)
./scripts/install.sh linux check        # Linux (or: web check)
```
```powershell
.\scripts\install.ps1 windows check     # Windows (or: web check)
```

Two things the installer can't do for you:

- **Mac desktop app:** the full **Xcode** app only comes from the Mac App
  Store (it's free). The installer opens its App Store page for you, then
  takes care of the license and first-launch setup. The web version doesn't
  need Xcode.
- **Windows:** turn on **Developer Mode** (Settings > System > For
  developers). Flutter's plugins need it. The installer opens that page for
  you if it's off.

A browser is all you need for the web version. Chrome is used if you have it
(Edge on Windows); otherwise the installer prints a link to open in any browser.

#### Install the prerequisites automatically

Add `deps` (or `-Deps` on Windows) and the installer sets up everything first,
then builds and opens the app. Even without it, the installer offers to
install anything that's missing.

```bash
./scripts/install.sh web deps         # Mac / Linux: set up, then run in the browser
./scripts/install.sh macos deps       # Mac: also set up the Mac desktop tools
./scripts/install.sh linux deps       # Linux: also set up the Linux desktop tools
```
```powershell
.\scripts\install.ps1 web -Deps       # Windows: set up, then run in the browser
.\scripts\install.ps1 windows -Deps   # Windows: also set up the desktop C++ tools
```

What gets installed (anything already there is skipped):

| Computer | Installs |
| --- | --- |
| **Mac** | Homebrew (official installer), Apple's Command Line Tools, Git, Flutter. For a Mac app: Xcode setup and CocoaPods. For web: Google Chrome (optional). |
| **Linux** (`apt`, `dnf`, `pacman` or `zypper`) | Git, curl, unzip, xz, zip and Flutter (via `snap`, or downloaded to `~/development/flutter`). For a Linux app: clang, CMake, Ninja, pkg-config, GTK 3, and the lzma, libstdc++, SQLite, libsecret and GLU libraries. For web: Chromium (optional). |
| **Windows** (`winget`, or Chocolatey) | Git, Flutter (downloaded to `%USERPROFILE%\development\flutter` and added to your PATH). For a Windows app: Visual Studio 2022 Build Tools with "Desktop development with C++". For web: Google Chrome (optional). SQLite comes bundled with the app. |

Flutter is downloaded from its official source, and the only script run from
the internet is Homebrew's own installer on Mac (after you confirm). When the
installer adds Flutter to your `PATH`, it offers to save that so new terminals
find it too. If a fresh install isn't found right away, open a new terminal
window and run the installer again.

---

### Mac and Linux

1. Open the **Terminal** app.
2. Go to the Spwrite folder. If it is on your Desktop, type:
   ```bash
   cd ~/Desktop/spwrite
   ```
3. The first time only, make the installer runnable:
   ```bash
   chmod +x scripts/install.sh
   ```
4. Run the installer. Pick one of these:

   **Open in a web browser (simplest):**
   ```bash
   ./scripts/install.sh web
   ```
   When it finishes it prints a link like `http://localhost:8080`. Open that in
   Chrome to start writing.

   **Build a Mac desktop app:**
   ```bash
   ./scripts/install.sh macos
   ```

   **Build a Linux desktop app:**
   ```bash
   ./scripts/install.sh linux
   ```

When a desktop build finishes, the installer prints the exact location of your
finished app so you can double-click it or drag it to your Desktop or
Applications folder.

---

### Windows

1. Open **PowerShell** (search for it in the Start menu).
2. Go to the Spwrite folder. If it is on your Desktop, type:
   ```powershell
   cd $HOME\Desktop\spwrite
   ```
3. Run the installer. Pick one of these:

   **Open in a web browser (simplest):**
   ```powershell
   .\scripts\install.ps1 web
   ```
   When it finishes it prints a link like `http://localhost:8080`. Open that in
   Chrome to start writing.

   **Build a Windows desktop app:**
   ```powershell
   .\scripts\install.ps1 windows
   ```
   When it finishes, the installer prints where your `.exe` app is. Double-click
   it, or copy the whole `Release` folder to your Desktop.

> If PowerShell refuses to run the script, paste this line first, then try
> again (it only affects the current window):
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```

---

## Handy extras

**Keep the terminal free while it runs.** Add the word `background` and the app
runs on its own, writing its messages to a log file instead of your terminal:

```bash
./scripts/install.sh web background      # Mac / Linux
```
```powershell
.\scripts\install.ps1 web background     # Windows
```

To stop a background run later:

- **Mac / Linux:** `kill $(cat spwrite-web.pid)`
- **Windows:** `Stop-Process -Id (Get-Content spwrite-web.pid)`

**Use a different web address/port.** By default the web version opens on port
`8080`. To change it:

```bash
WEB_PORT=9000 ./scripts/install.sh web           # Mac / Linux
```
```powershell
.\scripts\install.ps1 web -WebPort 9000          # Windows
```

**On a Linux server with no screen** (for example Ubuntu Server over SSH). The
Linux app needs a desktop to open its window. On a server, the installer still
builds it, then offers to install a lightweight desktop (XFCE) with a remote
desktop server (xrdp) so you can use Spwrite from your own computer:

```bash
./scripts/install.sh linux                        # on the server; say yes to the remote desktop
ssh -L 3389:localhost:3389 you@your-server        # on your own computer
```

Then open a Remote Desktop app (Windows App on Mac, Remote Desktop on Windows,
Remmina on Linux), connect to `localhost`, log in with your server account,
and run the `spwrite` path the installer printed. The SSH tunnel keeps the
remote desktop off the open network.

**The options at a glance:**

| Word you add | What it does |
| --- | --- |
| `web` | Runs Spwrite in Chrome |
| `macos` / `linux` / `windows` | Builds a double-clickable desktop app |
| `now` (default) | Runs in the current terminal window |
| `background` | Runs quietly on its own |
| `deps` (Mac/Linux) or `-Deps` (Windows) | Installs Flutter + build tools first, then continues |
| `check` (or `-Check` on Windows) | Only lists what's installed and what's missing; changes nothing |

You can combine a platform and a mode, e.g. `./scripts/install.sh macos now` or
`.\scripts\install.ps1 windows background`. Add `deps` / `-Deps` to any of them
to install the prerequisites first, e.g. `./scripts/install.sh macos deps` or
`.\scripts\install.ps1 windows -Deps`.

**Skip the confirmation prompts.** For an unattended install that answers "yes"
to every prompt, set `ASSUME_YES=1` (Mac/Linux) or pass `-AssumeYes` (Windows):

```bash
ASSUME_YES=1 ./scripts/install.sh web deps       # Mac / Linux
```
```powershell
.\scripts\install.ps1 web -Deps -AssumeYes        # Windows
```

---

## For developers

<details>
<summary>Manual setup and tests (click to expand)</summary>

The installer scripts wrap the standard Flutter workflow:

```bash
flutter pub get
# Web only — generate the SQLite WASM worker + binary:
dart run sqflite_common_ffi_web:setup
# Run in debug:
flutter run -d chrome     # web
flutter run -d macos      # macOS
flutter run -d linux      # Linux
flutter run -d windows    # Windows
```

Checks and tests:

```bash
flutter analyze
flutter test
```

Persistence is native SQLite on desktop and IndexedDB-backed WASM SQLite
on the web. The UI applies a single dark navy theme from `lib/theme/app_theme.dart`.

</details>

## Credits

- **Seanless** — product direction, requirements, and review.
- **Kiro** — implementation, tests, and tooling.
