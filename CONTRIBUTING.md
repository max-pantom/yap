# Contributing to Yap

Thanks for helping. Bug reports, fixes and focused features are all welcome.

## Build and run

```bash
./build.sh            # builds build/Yap.app (release, ad-hoc signed)
./build.sh --install  # also installs to /Applications and quits a running copy
```

Requires macOS 26+, Apple Silicon and the Command Line Tools. Xcode isn't needed. Note: SwiftUI's `@State`
macro plugin ships only with Xcode, so the project uses `@Local` (`Sources/Yap/Support/Local.swift`), a
macro-free drop-in. Please use it instead of `@State` so the project keeps building with the Command Line Tools.

## Code layout

```
Sources/Yap/
  App/         app entry, menu bar, windows, global hot keys, self-tests
  Dictation/   hotkey monitor, mic capture, speech engine, AI cleanup (Polisher), paste/selection (TextBridge)
  Models/      Whisper (WhisperKit) and second-model providers (Ollama, OpenAI-compatible), Keychain
  Recorder/    ScreenCaptureKit recording, camera bubble, post-processing (transcript, captions, AI notes)
  Library/     recordings + dictation history window
  UI/          Flow bar, overlays, settings, shortcuts, models
  Support/     preferences, permissions, devices, shortcuts, logging
scripts/       mark GIF/video renderers, icon renderers, set-icon.sh
design/mark/   the mark: source frames from Paper, tuned config (mark-config.json), Mark Lab (lab.html)
design/icon-glass/  app icon: Paper designs, Icon Composer layers, Liquid Glass renders
docs/          README images (icons, mark GIFs, Flow bar states)
```

## Debug tools

Run the binary directly with these flags (`build/Yap.app/Contents/MacOS/Yap …`), or pass them via
`open -a Yap.app --args …` after quitting Yap:

| Flag | What it does |
|---|---|
| `--selftest <audio>` | Runs speech → cleanup → Command Mode → recording insights on a file and prints timings |
| `--whisper-test <variant> <audio>` | Downloads a Whisper model, transcribes the file, then deletes the model |
| `--devices` | Lists cameras, microphones and keyboards Yap can see |
| `--deliver "<text>"` | Pastes text through the same path dictation uses |
| `--demo-bar <state>` | Shows the Flow bar in `idle`, `hover`, `listening`, `locked`, `thinking`, `pasted`, `error`, or the full `sequence` |
| `--slowmo <n>` | Plays Flow bar animations n× slower, for frame-by-frame review |
| `--settings` | Opens Settings on launch |

Environment: `YAP_MOTION_TRACE=1` prints per-frame timing and ring travel for the mark animation (smoothness checks).

Design tools in `scripts/`:

| Script | What it does |
|---|---|
| `mark-video.swift` | Renders the mark morph to MP4 (`swift scripts/mark-video.swift out.mp4 [speed] [loops] [size]`) |
| `mark-gif.swift` | Renders the mark loop to a GIF from `mark-config.json` (`swift scripts/mark-gif.swift out.gif 111111 ffffff`) |
| `render-glass-icon.sh` | Renders `Resources/AppIcon.icon` with Icon Composer's Liquid Glass renderer and installs it as the static icon |
| `icon-from-paper.swift` | Renders the flat icon variants from `design/icon-glass/paper` |
| `set-icon.sh` | Turns a 1024 PNG into `Resources/AppIcon.icns` |

`~/Library/Logs/Yap.log` records permission state, key events, timings and errors (never dictated text).

## Guidelines

- **Never block input.** The key monitor must stay a listen-only event tap; combos go through Carbon hot keys.
- **On-device by default.** Anything that sends data off the Mac must be opt-in and clearly labelled in the UI.
- **Motion:** state changes stay under 200 ms on a strong ease-out, no bounce; honour Reduce Motion. Use `Motion`
  tokens in `UI/FlowBar.swift`, and check animations with `--demo-bar sequence --slowmo 5`.
- Keep the build warning-free and match the surrounding code style.
- One focused change per pull request, with a short description of what you tested.
