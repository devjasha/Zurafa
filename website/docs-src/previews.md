# Files & images

Zurafa keeps the files your programs mention one click away, and lets you hand images to terminal programs such as coding agents.

## Preview a file

Hold `⌘` and click a file path in terminal output. Relative paths resolve against the pane's current directory. Zurafa opens a preview beside your panes:

- **Images** show at their full aspect ratio.
- **Markdown** renders with headings, lists, tables, and syntax-highlighted code blocks.
- **Org** files (`.org`) render the same way: headings, lists, tables, links, emphasis, and `#+BEGIN_SRC` blocks. Property drawers, comments, and `#+` keywords other than `#+TITLE` are hidden.
- **Math** in Markdown and Org renders as typeset LaTeX: `$…$` and `\(…\)` inline, `$$…$$`, `\[…\]`, and `equation`/`align`/`gather` environments as blocks. Custom macros (`\newcommand`) are not supported.
- **HTML** pages render live and can be interactive; see [Interactive pages](/docs/previews/#interactive-pages).
- **Code and plain text** are syntax highlighted in a monospaced view you can select and copy; long lines scroll horizontally.

When the file is inside a git repository, the preview header shows its status (Modified, Untracked, Added, …) and how many lines were added and removed compared with the last commit.

## Interactive pages

HTML files (`.html`, `.htm`) render as live pages, so a coding agent can show an explanation you can interact with: an animation you step through, a chart that updates, or Mermaid diagrams drawn in the page.

Elements can hand you a follow-up question. When a page calls `window.webkit.messageHandlers.zurafa.postMessage(text)`, for example from a click on a diagram node, Zurafa pastes `text` into the prompt of the pane that opened the preview. It is not submitted: edit it or press Enter yourself. Line breaks and control characters are stripped, and the text is capped at 500 characters.

Pages are sandboxed for this: requests to the network are blocked, links do not navigate away, and the page can only read files in its own folder. Put scripts and images it needs beside it. Pages that load scripts or fonts from the web will render without them.

Other programs can open the preview too: `zurafa preview PATH` shows the file beside the current pane, or beside the focused pane of the active tab when run outside Zurafa. Pass `-s` and `-b` to choose another session or pane.

Other file types show a short "no preview available" note. Directories, and paths that do not exist, open with the system default handler instead. Each workspace keeps its own preview, so switching workspaces leaves it behind. Close the preview with its close button.

## Paste an image

Paste (`⌘V`) while an image is on the clipboard, such as a screenshot or an image file copied in Finder. Zurafa saves it as a PNG in the system temporary folder and types the file path into the focused pane, followed by a space. Programs that accept image paths, such as Claude Code, can then read it.

Pasting text works as usual.

## Program icons

Tabs show an icon for each program running in their panes. Zurafa recognizes Claude Code, Codex, and Pi, including Pi launched through Node or the `pi-coding-agent` package; everything else shows a terminal icon.
