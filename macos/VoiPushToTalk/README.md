# Voi Push-to-Talk for Mac

Voi runs as a tiny macOS status-bar app.

- Hold `fn` to start listening.
- Release `fn` to stop.
- Voi transcribes, polishes, copies to the clipboard, and sends `Command-V` into the active app.

## Build

```sh
cd macos/VoiPushToTalk
Scripts/build-app.sh
open .build/Voi.app
```

On first launch, macOS will ask for:

- Microphone access, so Voi can record while `fn` is held.
- Accessibility access, so Voi can paste into the app you were using.

Set your Cartesia API key from the Voi menu-bar item.
