# Voi

Voi is a native macOS push-to-talk dictation app. Hold `fn`/Globe, speak, release, and Voi transcribes your speech into the app you were using.

## Download for testers

GitHub distribution is intended to happen through GitHub Releases:

1. Open the latest release.
2. Download `Voi-macOS-arm64.zip`.
3. Unzip it.
4. Move `Voi.app` to `/Applications`.
5. Open Voi.

On first launch, macOS asks for:

- Microphone access, so Voi can record while you hold `fn`/Globe.
- Accessibility access, so Voi can paste into the app you were using.

Voi also needs a speech API key. Open the Voi window, go to Settings, paste the key, then press Save.

## Gatekeeper note

Current builds are suitable for private testing. Apple notarization is not required to share a GitHub release with testers, but without it macOS may show a warning on first launch. If that happens, right-click Voi and choose Open.

For a smoother public release, sign with a trusted Developer ID certificate and notarize with Apple.

## Build locally

```sh
cd macos/VoiPushToTalk
Scripts/build-app.sh
open .build/Voi.app
```

## Package a GitHub release asset

```sh
cd macos/VoiPushToTalk
Scripts/package-release.sh
```

The release zip and checksum are written to `macos/VoiPushToTalk/.build/release-artifacts/`.
