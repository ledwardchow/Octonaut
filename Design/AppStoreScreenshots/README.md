# App Store screenshots

The finished PNGs are in `iPhone-6.9/`, `iPhone-Duo-Closed/`, `iPhone-Duo-Open/`, and `iPad-13/`. They use screenshots from the running iOS app with short captions and color backgrounds. The post text, comments, cat photo, and coast photo are synthetic sample content. No Reddit account or live posts are needed to make them. `05-save-media.png` shows the app's media viewer with its real save menu open on a two-image gallery.

The sample content is enabled only in Debug builds launched with `OCTONAUT_SCREENSHOT`. The generated photos are in `content/`, and the simulator captures used by the design script are in `raw/`.

To rebuild the artwork after replacing a capture, run:

```sh
python3 Design/AppStoreScreenshots/render.py
```

The script requires Pillow and macOS Avenir Next. It exports RGB PNGs at 1320 x 2868 for iPhone, 1398 x 2034 for the folded iPhone Duo cover screen, 2853 x 2007 for the open iPhone Duo inner screen, and 2064 x 2752 for iPad. The iPhone Duo artwork reuses the iPhone captions and colours. The open set skips the feeds image because the sidebar already shows feeds. The iPad artwork uses a portrait capture so the post images remain fully visible.

The screenshot build looks for `cat.png` and `coast.png` in the app bundle. Copy them from `content/` into the built simulator `.app` before installing it.
