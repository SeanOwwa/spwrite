/// Domain layer: the built-in **User Guide** project's content.
///
/// Plain data only. Keep it in sync with the app: when a feature changes,
/// update the matching document here and the installer rewrites the guide
/// on the next launch (its content fingerprint changes).
library;

import 'built_in_guide.dart';

/// Everything a writer needs to use Spwrite, as a read-only project.
class UserGuide extends BuiltInGuide {
  const UserGuide();

  @override
  String get projectId => 'builtin.user-guide';

  @override
  String get name => 'User Guide';

  @override
  List<GuideDocument> get rootDocuments => const <GuideDocument>[
        GuideDocument(title: 'Welcome', markdown: _welcome),
      ];

  @override
  List<GuideFolder> get folders => const <GuideFolder>[
        GuideFolder(
          name: 'Getting started',
          documents: <GuideDocument>[
            GuideDocument(title: 'Projects and the dashboard', markdown: _projects),
            GuideDocument(title: 'Folders and documents', markdown: _folders),
            GuideDocument(title: 'Writing and formatting', markdown: _writing),
            GuideDocument(title: 'Saving your work', markdown: _saving),
          ],
        ),
        GuideFolder(
          name: 'Writing tools',
          documents: <GuideDocument>[
            GuideDocument(title: 'Keyboard shortcuts', markdown: _shortcuts),
            GuideDocument(title: 'Focus mode and word count', markdown: _focus),
            GuideDocument(title: 'Characters', markdown: _characters),
            GuideDocument(title: 'Exporting to Word', markdown: _export),
          ],
        ),
        GuideFolder(
          name: 'Help',
          documents: <GuideDocument>[
            GuideDocument(title: 'AI assistant (coming soon)', markdown: _ai),
            GuideDocument(title: 'Your privacy', markdown: _privacy),
            GuideDocument(title: 'Troubleshooting', markdown: _troubleshooting),
            GuideDocument(title: 'About these guides', markdown: _aboutGuides),
          ],
        ),
      ];
}

const String _welcome = r'''
# Welcome to Spwrite

Spwrite is a quiet place to write long work: novels, scripts, essays and notes. Everything stays on your computer.

This User Guide is a normal Spwrite project that you can read but not change. Open a document on the left to read about one topic.

## Start in three steps

1. Go back to the dashboard with the arrow at the top left of the sidebar.
2. Click **New project**, give it a name, and optionally add a cover photo.
3. Open the project and click **Doc** to start writing.

## Where to go next

- **Getting started** covers projects, folders, documents, formatting and saving.
- **Writing tools** covers shortcuts, focus mode, characters and exporting.
- **Help** covers privacy, troubleshooting, and how to hide these guides.
''';

const String _projects = r'''
# Projects and the dashboard

A **project** holds one piece of work, such as a book. The dashboard shows all of your projects as cover cards, most recently edited first.

## Create a project

- Click **New project** at the top right, or press Cmd+N (Mac) or Ctrl+N (Windows and Linux).
- Type a name of up to 255 characters.
- Optionally choose a cover photo. It is resized to a book-cover shape for you.

## Open, edit or delete a project

- Click a card to open the project.
- Click the pencil on a card to rename it or change its cover.
- Click the bin on a card to delete it. You are asked to confirm, because deleting removes every folder, document and character inside it.

## The built-in guides

The **User Guide** and **Developer Guide** always appear first. They cannot be deleted or edited. Use the **Guides** switch next to New project to hide or show them.
''';

const String _folders = r'''
# Folders and documents

Inside a project, the sidebar on the left lists your **folders** and **documents**. Use folders for parts or books, and documents for chapters or scenes.

## Create

- **Folder** creates a new folder.
- **Doc** creates a document at the top level of the project.
- The page icon on a folder creates a document inside that folder.

## Rename and delete

Long-press (or press and hold) a folder or document to show its pencil and bin buttons. Deleting a folder also deletes the documents inside it, so you are asked to confirm.

## Reorder and move

- Drag the handle on the left of a row to change the order.
- Drag a document onto a folder to move it into that folder.
- Drag a document out of a folder onto the top-level list to move it back out.

## Rename the open document

Click its title at the top of the editor.
''';

const String _writing = r'''
# Writing and formatting

Click a document in the sidebar and start typing. The page uses a book typeface with double line spacing, like a manuscript.

## Formatting you can use

- **Bold** and *italic*
- Headings, in three sizes
- Numbered lists and bulleted lists
- Links

Choose them from the toolbar above the page, or use the shortcuts in **Keyboard shortcuts**. Hover over a toolbar button to see its shortcut.

## Handy typing features

- Type three hyphens in a row and they become an em dash (—). Undo straight after if you wanted the hyphens.
- Press Tab to indent the start of a paragraph.
- A document can hold up to one million characters. A notice appears at the top if you reach the limit.
''';

const String _saving = r'''
# Saving your work

Spwrite saves for you. You never need a Save button.

- Your writing is saved about two seconds after you stop typing.
- The small status chip at the top left of the toolbar shows **Saving…** and then **Saved**.
- Switching documents, closing a project, or quitting the app saves any last changes first.
- Press Cmd+S (Mac) or Ctrl+S (Windows and Linux) to save immediately, if that gives you peace of mind.

If the chip ever shows **Save failed**, keep the app open and type a character. The next save tries again. Your text stays on screen in the meantime.
''';

const String _shortcuts = r'''
# Keyboard shortcuts

On a Mac use **Cmd**. On Windows and Linux use **Ctrl** in the same place. Press Cmd+/ or Ctrl+/ in the editor to see this list at any time.

## Formatting

- Bold: Cmd+B
- Italic: Cmd+I
- Heading 1, 2 or 3: Cmd+1, Cmd+2, Cmd+3
- Normal text: Cmd+0
- Numbered list: Cmd+Shift+7 (also Cmd+Shift+O)
- Bulleted list: Cmd+Shift+8 (also Cmd+Shift+L)
- Insert or edit a link: Cmd+K

## Editing

- Undo: Cmd+Z
- Redo: Cmd+Shift+Z or Cmd+Y
- Find in the document: Cmd+F
- Save now: Cmd+S
- Indent a paragraph: Tab
- Em dash (—): type three hyphens

## View

- Focus mode: Cmd+Shift+F, and Esc to leave it
- Show or hide the sidebar: Cmd+Backslash
- Show or hide the AI assistant panel: Cmd+Shift+A
- This list: Cmd+/

## On the dashboard

- New project: Cmd+N
''';

const String _focus = r'''
# Focus mode and word count

## Focus mode

Press Cmd+Shift+F (Mac) or Ctrl+Shift+F (Windows and Linux) to hide everything except the page: the sidebar, title, toolbar and side panels step away. A small chip in the corner shows your word count. Press Esc, or the same shortcut again, to come back.

## Hide only the sidebar

Press Cmd+Backslash or Ctrl+Backslash to give the page more room while keeping the toolbar.

## Word count

The badge at the top right of the editor shows how many words the document has. While you write, it also shows how many words you have added since you opened the document, for example **1,240 words · +312**.
''';

const String _characters = r'''
# Characters

Keep track of the people in your story in the **Characters** panel.

- Click the people icon at the right of the toolbar to open the panel.
- Click **Add character**, then fill in a name, a role (for example Protagonist or Mentor) and details such as backstory, appearance and relationships.
- Add a picture if you like.
- Click a character to edit it later.

The Characters panel and the AI panel share the same space on the right, so opening one closes the other.
''';

const String _export = r'''
# Exporting to Word

You can export documents as a Word file (.docx) to share, print or send to an editor.

1. Click the download icon at the right of the toolbar.
2. Tick the documents to include, or use **Select all**.
3. On the desktop app, check **Save to** and use **Change…** to pick another folder. Spwrite remembers it next time.
4. Export. When it finishes, use **Show in folder** to find the file. In a web browser the file downloads instead.

Each document starts on a new page with its title as a heading, and keeps its bold, italic, headings and lists.
''';

const String _ai = r'''
# AI assistant (coming soon)

A private assistant that answers questions about your own documents and characters is on its way. It will run entirely on your computer.

It is not available in this version yet, and nothing needs to be downloaded. The AI button in the toolbar shows a **Coming soon** panel for now.
''';

const String _privacy = r'''
# Your privacy

- Your projects, documents and characters are stored only on this computer, in a local database.
- Spwrite has no account and sends your writing nowhere.
- Exports are saved only where you choose.
''';

const String _troubleshooting = r'''
# Troubleshooting

## My formatting disappeared after reopening a document

Older versions could save italic text with stray underscores. This is fixed, and affected documents are repaired automatically when you open them.

## The status chip says Save failed

Keep the app open and type a character to trigger another save. If it keeps failing, check that your disk is not full.

## A shortcut does nothing

Click inside the page first, so the editor has the keyboard. On some non-US keyboards the Backslash shortcut needs a different key combination.

## I can't edit this guide

That is expected. The built-in guides are read-only so they stay accurate. Create your own project to write.
''';

const String _aboutGuides = r'''
# About these guides

Spwrite comes with two read-only projects:

- **User Guide**, which you are reading, explains how to use the app.
- **Developer Guide** explains how the app is built, for anyone who wants to work on its code.

They update automatically when a new version of Spwrite changes them. They cannot be deleted, but you can hide them: on the dashboard, turn off the **Guides** switch next to **New project**. Turn it back on any time.
''';
