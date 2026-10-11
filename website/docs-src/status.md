# Program status protocol

Zurafa supports structured program-status reports through OSC 7501. Compatible programs can report `idle`, `working`, `done`, `blocked`, or `error`; a `clear` report removes a record. The Rust terminal reader parses these sequences, manages per-terminal records, and emits status events. Zurafa does not infer an agent's state by scraping ordinary terminal text.

## What you see

The macOS app shows a small status indicator for a terminal or tab when a supported report is active. Multiple records can coexist within one terminal, so a program can represent nested tasks. The frontend receives `terminal.program_status_changed` and `terminal.program_status_removed` events and refreshes after reconnecting from the Rust snapshot.

## Send a report

The current wire format is `ESC ] 7501 ; key=value (: key=value)* ST`. Here `ST` can be BEL or `ESC` followed by `\`. Fields include `state`, `id`, base64-encoded `msg` and `title`, optional `kind`, `progress`, and `app`. IDs form a bounded slash-separated hierarchy; omitting `id` targets the root record. Each report replaces that record rather than merging missing fields.

For a complete explanation of validation, hierarchy, clear semantics, lifetime, and limits, read the [OSC 7501 section of the IPC reference](/docs/ipc-reference/#osc-7501-records) and the [Rex Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).

## Lifecycle

Clear removes a record and its descendants. Full terminal reset removes all records. A shell-prompt marker or child exit removes active `working` and `blocked` records; stable `idle`, `done`, and `error` records can remain until another lifecycle operation removes them. The daemon publishes changed and removed events only after the record store actually changes.

## Distinct terminal reports

OSC 9;4 terminal progress reports are a separate `terminal.progress_report` event. They are not OSC 7501 records. Terminal title, working directory, bell, notification, process, and exit reports also have their own event types. See [Architecture & events](/docs/architecture/).
