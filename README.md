# Sago Media

A native macOS menu-bar client for `media.hsichen.dev`. It talks directly to
the service and stores its device credential in macOS Keychain.

## Run

Build and launch the menu-bar app:

```bash
scripts/build-app
open ".build/Sago Media.app"
```

Choose **Sign in** once and approve the device in the browser. Drop files onto
the menu-bar icon or popover drop target; successful uploads copy their public
URL to the clipboard.
