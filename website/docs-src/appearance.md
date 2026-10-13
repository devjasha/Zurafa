# Appearance & Ghostty settings

Zurafa offers Follow System, Light, and Dark modes. Open `⌘K` and choose an appearance directly; the change takes effect immediately. `⇧⌘A` switches between light and dark in one press. Follow System updates with the macOS appearance. Zurafa remembers your choice across launches.

## Configuration file

Press `⌘,` to open `~/.config/config.zurafa` (or `$XDG_CONFIG_HOME/config.zurafa`) in your default text editor. The first time, Zurafa writes a commented template that lists every setting; remove the `#` in front of a line to use it. Changes apply a moment after you save, and deleting a line returns that setting to its default.

```
theme = light:Catppuccin Latte,dark:Catppuccin Mocha
accent-color = #3a69cc
window-opacity = 0.9
pane-gap = 8
pane-padding = 12
pane-corner-radius = 14
unfocused-pane-opacity = 0.7
sidebar-width = 194
```

`theme` accepts any Ghostty theme name from `~/.config/ghostty/themes` or Ghostty.app, and the whole app follows its colors, including the command picker. Terminal colors and fonts (`foreground`, `background`, `cursor-color`, `palette`, `font-family`, `font-size`) override the theme. Values in this file also override imported Ghostty settings. Out-of-range values are ignored.

## Import Ghostty settings

Choose **Import Ghostty Settings** from `⌘K`. Zurafa reads Ghostty's standard XDG and macOS configuration paths, including supported includes and named light and dark themes. The import can apply the terminal font family, font size, foreground and background colors, cursor and selection colors, and the ANSI palette.

The imported background color tints the entire workspace surface; terminal drawing areas stay transparent so the pane and window feel continuous. Color changes remain local to Zurafa after import. If you later edit Ghostty's files, run the import again to refresh Zurafa's copy.

Choose **Use Zurafa Terminal Defaults** in `⌘K` to clear the imported settings. Ghostty keybindings, shell commands, and window layout are outside the import scope.

## Icons and fonts

Zurafa bundles Symbols Nerd Font Mono as a fallback for missing Nerd Font glyphs in terminal content. Your selected terminal font still renders ordinary text and glyphs it already contains. Zurafa also uses foreground-process information reported by the Rust PTY manager to choose pane and tab program icons when that information is available.

## Background images

You can add a dithered image behind the workspace separately from Ghostty color import. See [Dithered backgrounds](/docs/backgrounds/) for selection, storage, and toggling.
