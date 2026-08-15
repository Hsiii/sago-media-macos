# Sago Media

A native macOS menu-bar client for `media.hsichen.dev`.

## Run

Authenticate once with the shared CLI:

```bash
npx sago-media auth login
```

Build and launch the menu-bar app:

```bash
scripts/build-app
open ".build/Sago Media.app"
```

Drop files onto the menu-bar icon or the popover drop target. Successful uploads copy their public URL to the clipboard. The app uses an installed `sago-media` command when available and otherwise runs the pinned `sago-media@0.1.0` client.
