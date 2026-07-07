# Voi Push-to-Talk for Mac

Voi runs as a tiny macOS status-bar app.

- Hold `fn`/Globe to start listening.
- Release `fn`/Globe to stop.
- Voi transcribes, polishes, copies to the clipboard, and sends `Command-V` into the active app.

## Build

```sh
cd macos/VoiPushToTalk
Scripts/build-app.sh
open .build/Voi.app
```

On first launch, macOS will ask for:

- Microphone access, so Voi can record while `fn`/Globe is held.
- Accessibility access, so Voi can paste into the app you were using.

Set your speech API key from the Voi Settings tab.

## Package for GitHub Releases

```sh
cd macos/VoiPushToTalk
Scripts/package-release.sh
```

This creates:

- `.build/release-artifacts/Voi-macOS-arm64.zip`
- `.build/release-artifacts/Voi-macOS-arm64.zip.sha256`

Upload both files to a GitHub Release.

## Distribution status

The zip is fine for private testers. Apple notarization is optional for GitHub tester builds, but it avoids first-launch macOS warnings for broader public distribution.
