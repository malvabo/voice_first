# Voi Push-to-Talk for Mac

Voi runs as a tiny macOS status-bar app.

- Hold `Option`-`Space` to start listening (`fn`/Globe is experimental).
- Release to stop.
- Voi transcribes, polishes, copies to the clipboard, and sends `Command-V` into the app you were using.

## Build

```sh
cd macos/VoiPushToTalk
Scripts/build-app.sh
open .build/Voi.app
```

### Optional but recommended: stable signing identity

By default the build is ad-hoc signed, which means macOS treats each rebuild as
a new app and **resets the Accessibility / Input Monitoring permissions** every
time. Create a persistent local code-signing identity once:

```sh
Scripts/create-signing-cert.sh
```

After that, `build-app.sh` signs Voi with a stable signature and your granted
permissions survive rebuilds.

## Permissions

Voi needs **two** separate macOS permissions — both are required for dictation
to land in other apps:

- **Microphone** — to record while the hotkey is held.
- **Input Monitoring** — to detect the `Option`-`Space` hotkey globally.
- **Accessibility** — to paste the transcribed text into the app you were using.
  Without this, the text is still copied to the clipboard but cannot be pasted
  automatically. Enable Voi under System Settings → Privacy & Security →
  Accessibility.

The dashboard's "Setup health" chips show the live state of each permission.

Set your Cartesia API key from the Voi menu-bar item or the dashboard.
