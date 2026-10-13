# Zurafa 0.1.4

- Fixes a bug introduced in 0.1.3 where the app would not launch: the bundled `zurafa` CLI binary was overwriting the app's own executable on case-insensitive filesystems, so opening Zurafa.app ran the CLI instead of the GUI. The CLI now ships at `Zurafa.app/Contents/Resources/zurafa`.
