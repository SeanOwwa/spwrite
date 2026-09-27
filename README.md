# Spwrite

A calm, distraction-free writing app for your own computer. Organize your work
into **projects**, **folders**, and **documents**, and write in a clean editor
that looks like a manuscript. Everything is saved on your machine (or in your
browser on the web), so your writing is always with you and works offline.

## What it looks like

- **Serif text, double-spaced.** The editor uses a classic serif typeface with
  2.0 (double) line spacing — the same standard as a Google Docs manuscript —
  so your drafts are easy on the eyes and easy to mark up.
- **Live word count.** A running word count sits in the upper-right corner of
  the document, updating as you type.
- **Deep navy theme.** A dark, navy-blue workspace with dark-cyan highlights,
  designed to be gentle for long writing sessions.

## What you can do

- Keep separate **projects** for different books, articles, or clients.
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
- **Export to Word.** Send any selection of documents to a single `.docx` file
  from the export icon in the editor toolbar. Each document's title becomes a
  heading and its text the body, with every document starting on a new page.
- **Character Panel.** Keep your cast close while you write. Open it from the
  people icon on the right of the editor toolbar to see a scrollable list of
  your characters. Each one has a name, role, free-form details, and a portrait
  image. The sidebar shows a short preview of the details; tap "See more" to
  read the full details right there, or open one to edit it on its own screen.
- **Autosave.** Your work saves itself as you go; there is no Save button to
  remember.

---

## Getting started

You do not need to be technical to install Spwrite. Follow the section for your
computer below. The first time you run it, the installer downloads what it needs
and builds the app — this can take a few minutes. After that it is quick.

### Before you begin (one-time)

Spwrite is built with a free tool called **Flutter**. If you do not already have
it, the installer will stop and give you a link to install it. You can install
it ahead of time from the
[Flutter install guide](https://docs.flutter.dev/get-started/install).

- **To use Spwrite in a web browser**, you also need **Google Chrome**.
- **To get a desktop app** (an icon you double-click), you need your system's
  developer tools: **Xcode** on Mac, **Visual Studio** with "Desktop
  development with C++" on Windows, or the **C/C++ build tools and GTK** on
  Linux. The Flutter install guide walks you through this.

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

**The two options at a glance:**

| Word you add | What it does |
| --- | --- |
| `web` | Runs Spwrite in Chrome |
| `macos` / `linux` / `windows` | Builds a double-clickable desktop app |
| `now` (default) | Runs in the current terminal window |
| `background` | Runs quietly on its own |

You can combine a platform and a mode, e.g. `./scripts/install.sh macos now` or
`.\scripts\install.ps1 windows background`.

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

Persistence is native SQLite on desktop/mobile and IndexedDB-backed WASM SQLite
on the web. The UI applies a single dark navy theme from `lib/theme/app_theme.dart`.

</details>

## Credits

- **Seanless** — product direction, requirements, and review.
- **Kiro** — implementation, tests, and tooling.
