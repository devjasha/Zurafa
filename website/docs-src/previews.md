# Files & images

Zurafa keeps the files your programs mention one click away, and lets you hand images to terminal programs such as coding agents.

## Preview a file

Hold `⌘` and click a file path in terminal output. Relative paths resolve against the pane's current directory. Zurafa opens a preview beside your panes:

- **Images** show at their full aspect ratio.
- **Markdown** files render as formatted text.
- **Code and plain text** show in a monospaced view you can select and copy.

Other file types show a short "no preview available" note. Directories, and paths that do not exist, open with the system default handler instead. Close the preview with its close button.

## Paste an image

Paste (`⌘V`) while an image is on the clipboard, such as a screenshot or an image file copied in Finder. Zurafa saves it as a PNG in the system temporary folder and types the file path into the focused pane, followed by a space. Programs that accept image paths, such as Claude Code, can then read it.

Pasting text works as usual.

## Program icons

Tabs show an icon for each program running in their panes. Zurafa recognizes Claude Code, Codex, and Pi, including Pi launched through Node or the `pi-coding-agent` package; everything else shows a terminal icon.
