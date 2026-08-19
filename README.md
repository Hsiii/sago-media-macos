<h1 align="center">Sago Drop</h1>
<div align="center">

  Turn Mac screen recordings that are too large for Discord into links you can paste instead.

  <a href="https://github.com/sago-cream/sago-drop/releases/latest">Download latest release</a>
   ·
  <a href="#install">Install with Homebrew</a>
</div>

## Why

Discord rejects videos once they get too large, but sending a link is easy. Drop
the recording on Sago Drop's menu-bar icon; it normalizes the video locally,
uploads the video, and copies a share link ready to paste into Discord.

Sago Drop also uploads images and other videos when you want the same quick
drop-to-link workflow.

- **Drop, paste, or choose:** Upload directly from the menu bar without opening
  a full app window, or turn clipboard content into a file in Downloads.
- **Made for Apple recordings:** Normalize MOV and MP4 files locally to a
  shareable 1080p H.264 MP4 before upload.
- **Link copied automatically:** Paste into Discord as soon as the upload
  finishes.
- **Native and local where it matters:** The app is signed and notarized, video
  processing stays on the Mac, and its device credential lives in Keychain.

## Install

Install with Homebrew:

```bash
brew install --cask sago-cream/tap/sago-drop
```

Or download the latest signed and notarized app from
[GitHub Releases](https://github.com/sago-cream/sago-drop/releases/latest).

Requirements:

- macOS 14 Sonoma or newer
- Access approved by the Sago Media administrator

## First Run

1. Open Sago Drop from Applications. It appears in the menu bar instead of the
   Dock.
2. Choose **Sign In** from its menu.
3. Approve the displayed request in your browser.

Uploads work once access is approved. The credential is saved in Keychain, so
signing in is normally a one-time step.

## Upload

- Drag supported files directly onto the menu-bar icon.
- Copy files in Finder and choose **Upload Copied Files** (`⇧⌘V`).
- Copy other content and choose **Save Clipboard** (`⌘V`) to save it as a
  file in Downloads.
- Choose **Upload Files…** (`⌘O`) to use the standard file picker.

The menu-bar icon shows conversion and upload progress. After a successful
upload, the public share URL is copied automatically. The five latest uploads
remain available under **Recent Uploads**.

## Formats and Limits

- MOV and MP4 videos are normalized locally to 1080p H.264/AAC MP4 and targeted
  below 80 MB before upload.
- Other supported files must already be under 90 MB.
- Supported formats: PNG, JPEG, GIF, WebP, MOV, and MP4.

## Privacy

- The device credential is stored in macOS Keychain.
- Video processing happens locally on the Mac.
- Files are uploaded to `media.hsichen.dev` and receive a public share URL.
- Sago Drop has no analytics or background file scanning.

## Troubleshooting

- **An upload asks you to sign in:** Choose **Sign In** and finish the browser
  approval before trying again.
- **A file is rejected:** Check its format and the limits above. MOV and MP4
  files are prepared locally; images must fit the upload limit already.
- **Homebrew installed an older version:** Run `brew update`, then
  `brew upgrade --cask sago-cream/tap/sago-drop`.
- **Two menu-bar icons appear:** Quit either the development build or the
  installed app so only one copy remains open.

## Development

Run directly from the source tree:

```bash
swift run
```

Build and launch a local app bundle:

```bash
scripts/build-app
open ".build/Sago Drop.app"
```

Run the agent-safe upload progress smoke suite:

```bash
scripts/smoke-upload-progress
```

The suite uses a throttled localhost server and debug-only credentials to test
successful and failed uploads without reading Keychain or creating public media.

## Maintainer Release

`scripts/package-app <version>` builds the hardened-runtime app, signs it with
the configured Developer ID Application certificate, notarizes it when
`SAGO_DROP_NOTARY_PROFILE` is set, and creates the release ZIP and Homebrew
cask in `dist/`.

Release from a clean `main` that exactly matches `origin/main`:

```bash
scripts/release <version> "<user-facing change>"
```

The release script uses the `Sago Drop` notarytool Keychain profile by default,
publishes the ZIP and cask without changing `main`, then updates
`sago-cream/homebrew-tap` using the current GitHub CLI login. If only the tap
update needs to be retried, run `scripts/update-homebrew <version>`.

## License

[MIT](LICENSE)
