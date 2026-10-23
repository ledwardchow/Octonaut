# Media gallery

Move between images in the full screen gallery.

## Sub-features

- `media-open`: open a post image.
- `media-page`: change the displayed gallery image.
- `media-dismiss`: close the viewer.

## How to get to it (user POV)

Tap an image in a feed or post detail. A direct media launch is available for the two-image sample gallery.

## Driving it with XcodeBuildMCP

Preconditions: Launch with `media` for the two-image sample. Capture the coast image and available paging controls. Swipe horizontally in the viewer to the cat image and require the displayed image to change. Swipe back and require the coast image. Use the visible close control to dismiss. Separately launch `feeds`, open Home, and tap a sample image to verify the feed entry. Save before/after screenshots and the gesture responses.

## Gotchas

- Direct media launch replaces the root view. Dismissal may have no parent to return to; verify return through the feed entry separately.
- This fixture has images, not a playable video. It does not verify audio, export, Photos permission, or network downloads.
- Do not invoke Save to Photos or external sharing during this check.
