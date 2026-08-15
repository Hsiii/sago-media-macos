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

## Distribution

`scripts/package-app 0.1.0` builds a hardened-runtime app signed with the local
Developer ID Application certificate, notarizes it when
`SAGO_MEDIA_NOTARY_PROFILE` is set, and creates both the release ZIP and a
Homebrew cask in `dist/`.

After release changes are merged through a pull request, release from a clean,
up-to-date `main`:

```bash
scripts/release 0.1.0 "Upload files from the menu bar"
```

The release script uses the `Sago Media` notarytool Keychain profile by default,
publishes the notarized ZIP and cask without changing `main`, and leaves the
generated cask ready for a pull request to `Hsiii/homebrew-tap`.
