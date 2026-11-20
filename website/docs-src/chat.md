# Agent chats

A pane running Claude Code, Codex or Pi can show its conversation as a chat instead of its terminal. The agent keeps running in the terminal underneath; the chat reads its transcript and types into it for you.

## Open a chat

Agent panes open as a chat by default. To change that for every pane, turn off **Show agents as chat** in Settings → Integrations → Chat, or set `agent-chat = false` in the config file.

- `⌥⌘C` (**Chat or Terminal** in `⌘K`) flips the focused agent pane between its chat and its terminal.
- `⇧⌘O` (**New Chat**) starts Claude Code, Codex or Pi in a new tab, which opens as a chat.

A chat opens on its newest turns. Click **Show earlier messages** at the top for older ones. Switching tabs and back shows the chat at once, without loading it again.

## What a chat shows

Each turn is one exchange:

- **Your message** in a bubble on the right.
- **The work**, folded into one line such as "Claude worked for 1m 56s". While the agent runs, Zurafa's star turns in place of its icon and the clock shimmers. The work shows while the agent is on it and folds away once it answers.
- **Tool calls** as quiet rows, such as "Read main.rs", with commands and queries as written. Click a row to see its output.
- **Edits** show their line counts (`+12 −3`). Opening one shows its diff in the file's syntax colors: removed lines on red, added lines on green.
- **Changed files** are listed under the turn with their line counts. Click one to open it in the [preview](/docs/previews/).
- **The answer** as Markdown: headings, lists, quotes, tables and code blocks with a copy button. A copy button copies the whole answer.

Chats are laid out in a reading column, so a wide pane centers the chat instead of stretching its lines.

## When the agent needs you

- **Questions.** When the agent asks a question with options, a card shows it with its options to pick, one question at a time. Pick one or more, or choose **Other** and type your own answer, then **Continue** or **Submit**. Zurafa answers in the terminal for you. **Skip** dismisses the question, as Esc does in the terminal.
- **Permission prompts.** Claude Code's permission prompt shows **Deny** and **Allow** above the composer. Return allows.
- **Anything else** that waits on you shows its message and **Answer in Terminal**, which flips the pane to its terminal.

## The composer

The composer sits at the bottom of the chat. Return sends; `⌥↩` adds a new line. Messages arrive as a paste followed by Enter, as `zurafa send` types them, so a multi-line message arrives whole.

- Type `/` for the agent's commands and skills, and `@` for files in the folder the agent works in. The suggestions open above the composer; pick one with the arrow keys and Return, or close them with Esc.
- **Images**: paste one with `⌘V` or drop image files on the composer. They show as thumbnails above the text and are sent ahead of it as `@` mentions.
- **+** opens **Add to message**: **Upload file** attaches files or images, and **Plan mode** asks for a plan to review before building (Claude Code).
- The **model** chip shows the model with its reasoning effort. Hover **Reasoning** or **Model** to pick one; the model list has a search field.
- The **access** chip sets the permission mode: **Supervised**, **Auto-accept edits**, **Auto** or **Full access**. Pi has no access chip.

Under the composer are the folder the agent works in, its git branch, and a spinner while it runs.

Only a running Claude Code takes model, effort and access changes, and it keeps a change as your default for new sessions. Codex and Pi take them only when they start, so their chips show what they started with: pick them in a new chat instead.

## New Chat

`⇧⌘O` opens **What should we work on?** Pick the agent from the model panel's rail, its model, effort and access, and the folder, and choose the Zurafa session to work in. Type what to do and send: the agent starts in a new tab of that session and the pane shows it as a chat.

## Remote panes

A chat works in a pane on an [SSH](/docs/ssh/) or [direct](/docs/remote-access/) host too. The agent writes its transcript on that host; the daemon follows it there and the chat reads its lines, so you see the whole chat, not just the answers.

## On the iPhone

The [iPhone app](/docs/iphone/) shows agent panes as a chat too, with the same turns, folded work, diffs, question cards and composer menus. The phone's composer adds a few things:

- **⌘** next to Send: tap for Escape and control keys, hold for your quick actions.
- The paperclip attaches photos from the **Photo Library** or **Files**. They show as thumbnails above the text and go with the message as `@` mentions.
- Unsent drafts are kept per pane, through leaving the pane, flipping to the terminal and relaunching the app.

To open agents as their terminal instead, turn off **Open Agents as Chat** in the app's Settings. **•••** → **Show Terminal** or **Show Chat** flips one pane, and **New Chat** in the same menu starts an agent on the Mac.
