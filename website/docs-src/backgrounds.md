# Dithered backgrounds

Zurafa can place a softly visible, dithered image behind the workspace. It is optional and can be switched off without deleting the selected image.

## Set an image

1. Open the command picker with `⌘K`.
2. Choose **Set Background Image…**.
3. Select an image from the macOS file picker.

Zurafa resizes large images before processing them and applies an ordered Bayer dither with a limited color palette. It saves the processed PNG in Zurafa's Application Support directory, so moving or deleting the original file does not break the background.

## Show or hide it

Open `⌘K` and choose **Hide Background Image** or **Show Background Image**. The selection and toggle state persist across launches. Choosing **Set Background Image…** again replaces the saved background.

The image is intentionally subtle so terminal text remains readable. Imported Ghostty background color, if any, still tints the workspace beneath it.
