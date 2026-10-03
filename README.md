# Spwrite

**Beta 1.3.4** · macOS, Windows, Linux and web

Spwrite is a calm writing app for long work: novels, scripts, essays and notes.
It runs on your own computer, works offline, and keeps your writing private.
There's no account and nothing to pay.

> New to Spwrite? Open the **User Guide** project on the dashboard. It walks
> through every feature inside the app.

---

## Contents

- [What you can do](#what-you-can-do)
- [Install Spwrite](#install-spwrite)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Your privacy](#your-privacy)
- [AI assistant (coming soon)](#ai-assistant-coming-soon)
- [Troubleshooting](#troubleshooting)
- [For developers](#for-developers)

---

## What you can do

### Organize your work

- **Projects** for each book, article or client, shown as book-cover cards.
  Add a cover photo if you like.
- **Folders and documents** inside each project, for parts, chapters and
  scenes.
- **Drag to reorder.** Drag a document onto a folder to move it in, or back out
  to the top level.
- Rename and delete buttons stay hidden until you long-press a row, so the
  sidebar stays clean.

### Write comfortably

- A manuscript-style page: book serif type, double line spacing, and a
  comfortable line width.
- **Formatting:** bold, italic, headings, numbered and bulleted lists, and
  links.
- **Focus mode** hides everything except the page.
- **Word count**, plus how many words you've added since opening the document.
- **Small touches:** type `---` for an em dash (—), and press Tab to indent a
  paragraph.

### Never lose a word

- **Autosave.** Your text saves itself a couple of seconds after you stop
  typing. A small chip shows **Saving…** and then **Saved**.
- Switching documents, closing a project or quitting the app saves first.

### Keep your cast close

- The **Characters** panel holds each character's name, role, details and
  picture, right beside your draft.

### Share your work

- **Export to Word (.docx).** Pick the documents you want. Each one starts on a
  new page with its title as a heading.

### Built-in guides

- **User Guide**: how to use every feature.
- **Developer Guide**: how the app is built, for anyone working on the code.
- Both are read-only and can't be deleted. Turn off the **Guides** switch next
  to **New project** to hide them.

---

## Install Spwrite

You don't need to be technical. An installer script checks your computer,
offers to install anything missing (it asks first), and builds the app. The
first run takes a few minutes; later runs are quick.

### Mac and Linux

1. Open the **Terminal** app.
2. Go to the Spwrite folder, for example:
   ```bash
   cd ~/Desktop/spwrite
   ```
3. The first time only, allow the installer to run:
   ```bash
   chmod +x scripts/install.sh
   ```
4. Choose one:

   | To… | Run |
   | --- | --- |
   | Build the Mac app | `./scripts/install.sh macos` |
   | Build the Linux app | `./scripts/install.sh linux` |
   | Use it in your web browser | `./scripts/install.sh web` |

When it finishes, the installer prints where your app is. Double-click it, or
drag it to Applications (Mac).

### Windows

1. Open **PowerShell** from the Start menu.
2. Go to the Spwrite folder, for example:
   ```powershell
   cd $HOME\Desktop\spwrite
   ```
3. Choose one:

   | To… | Run |
   | --- | --- |
   | Build the Windows app | `.\scripts\install.ps1 windows` |
   | Use it in your web browser | `.\scripts\install.ps1 web` |

If PowerShell won't run the script, paste this first. It only affects the
current window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Two things to do yourself

- **Mac app:** install **Xcode** from the Mac App Store (free). The installer
  opens the page for you. The web version doesn't need it.
- **Windows app:** turn on **Developer Mode** in Settings > System > For
  developers. The installer opens the page for you.

> Each desktop app must be built on its own system: the Mac app on a Mac, the
> Windows app on Windows, the Linux app on Linux.

<details>
<summary><strong>More installer options</strong></summary>

Add any of these words after the platform, for example
`./scripts/install.sh macos deps`.

| Word | What it does |
| --- | --- |
| `deps` (Windows: `-Deps`) | Installs Flutter and the build tools first, then continues |
| `check` (Windows: `-Check`) | Only lists what's installed and what's missing |
| `background` | Runs the app on its own, writing messages to a log file |
| `now` (default) | Runs in the current terminal window |

**Answer "yes" to every prompt:** set `ASSUME_YES=1` on Mac and Linux, or add
`-AssumeYes` on Windows.

**Change the web port** (default 8080): `WEB_PORT=9000 ./scripts/install.sh web`
on Mac and Linux, or `.\scripts\install.ps1 web -WebPort 9000` on Windows.

**Stop a background run:** `kill $(cat spwrite-web.pid)` on Mac and Linux, or
`Stop-Process -Id (Get-Content spwrite-web.pid)` on Windows.

**What gets installed** (anything already present is skipped):

| Computer | Tools |
| --- | --- |
| Mac | Homebrew, Command Line Tools, Git, Flutter; for the Mac app also Xcode setup and CocoaPods |
| Linux | Git, curl, unzip, xz, zip, Flutter; for the Linux app also clang, GCC, CMake, Ninja, pkg-config, GTK 3 and a few libraries |
| Windows | Git, Flutter; for the Windows app also Visual Studio 2022 Build Tools (C++) |

**Linux server without a screen** (for example Ubuntu Server over SSH): the
installer still builds the app and offers to set up a lightweight remote
desktop (XFCE and xrdp). Connect through an SSH tunnel with
`ssh -L 3389:localhost:3389 you@your-server`, then open a Remote Desktop app
to `localhost`.

</details>

---

## Keyboard shortcuts

Use **Cmd** on a Mac and **Ctrl** on Windows and Linux. In the editor, press
Cmd+/ or Ctrl+/ to see this list.

| Action | Shortcut |
| --- | --- |
| Bold / italic / link | Cmd+B / Cmd+I / Cmd+K |
| Heading 1, 2, 3 / normal text | Cmd+1, 2, 3 / Cmd+0 |
| Numbered / bulleted list | Cmd+Shift+7 / Cmd+Shift+8 |
| Undo / redo | Cmd+Z / Cmd+Shift+Z |
| Find in document | Cmd+F |
| Save now | Cmd+S |
| Focus mode (Esc to leave) | Cmd+Shift+F |
| Show or hide the sidebar | Cmd+Backslash |
| New project (dashboard) | Cmd+N |
| Em dash (—) | type `---` |

---

## Your privacy

- Your projects, documents and characters are stored only on your computer. In
  the web version they're stored in your browser.
- Spwrite has no account and sends your writing nowhere.
- Exports are saved only where you choose.

---

## AI assistant (coming soon)

A private writing assistant that answers questions about your own documents and
characters is being finished. It will run entirely on your computer, with no
account and no cost.

In this version the AI button shows **Coming soon**. Nothing is downloaded and
nothing runs in the background.

---

## Troubleshooting

**The status chip says "Save failed".** Keep the app open and type a character
to try again. If it keeps failing, check that your disk isn't full.

**A shortcut does nothing.** Click inside the page first, so the editor has the
keyboard.

**I can't edit the User Guide or Developer Guide.** That's intended: they're
read-only so they stay accurate. Create your own project to write.

**The installer can't find Flutter after installing it.** Open a new terminal
window and run the installer again.

**What changed in this version?** See [CHANGELOG.md](CHANGELOG.md).

---

## For developers

The **Developer Guide** project inside the app explains the architecture
(domain, data, state and presentation layers, and how SOLID applies), the
database, each feature, and the conventions to follow.

Quick reference:

```bash
flutter pub get                               # get packages
dart run sqflite_common_ffi_web:setup         # web only, once
flutter run -d macos                          # or windows, linux, chrome
flutter analyze                               # static checks
flutter test                                  # run all tests
flutter build macos --release                 # or windows, linux, web
```

Desktop apps store data in native SQLite; the web version uses SQLite in the
browser (IndexedDB). The theme lives in `lib/theme/app_theme.dart`.

The on-device AI assistant is developed on the `ai_feature` branch.

---

## Credits

- **Seanless**: product direction, requirements and review.
- **Kiro**: implementation, tests and tooling.
