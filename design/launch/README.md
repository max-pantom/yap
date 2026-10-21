# Launch film

A 16-second, 1920×1080 launch video for Yap 1.1, in the look of [yap.primitive8.cc](https://yap.primitive8.cc):
white paper, Geist and the live Yap mark (Yap's own `mark-config.json` values). `launch.html` is v2, one continuous
camera inspired by product films: kinetic type the camera tracks, a zoom through the mark, windows that orbit in
perspective with soft out-of-focus windows behind, whip pans and motion blur. `launch-v1.html` is the first, calmer
cut in the site's feature-card layout.

| Time | v2 |
|---|---|
| 0–2.5 s | "What if you could [Flow bar] just say it?" word by word, then the camera dives through the mark |
| 2.5–5 s | Just say it: "3, no wait," falls away and "Ship it Thursday at 4." flies into the chat |
| 5–8.4 s | Show, don't tell: 3‑2‑1 flies past the camera, a click, and the auto-zoom is a camera push |
| 8.4–11.5 s | Every call, noted (new): the transcript lands word by word, action items tick off |
| 11.5–13.8 s | Pull back to all three as floating cards: "No account. No cloud. All on your Mac." |
| 13.8–16 s | The meeting card folds into the Flow bar; its mark lifts out and grows into the logo through all five keyframes · "Less typing. More yapping." · yap.primitive8.cc |

Every frame is drawn by `draw(t)` in `launch.html`, so the preview and the export are identical.

```bash
node design/launch/serve.mjs     # then open http://127.0.0.1:3010 and press Export MP4
```

Export encodes frame by frame (WebCodecs + mp4-muxer), mixes in `audio/mix.wav` (music + effects) as AAC, and saves
`out/yap-launch-v3.mp4` and a poster frame (v1 saves `out/yap-launch.mp4`). The Flow bar is drawn to the app's
own spec in `FlowBar.swift` at 2×. The sound effects are synthesized by `audio/make_sfx.py` (see `audio/README.md`). The soundtrack is a small synthesized music bed (A major, 100 bpm) under the effects; stems are `audio/music.wav` and `audio/sfx.wav`.

The Geist fonts in `fonts/` are © Vercel, under the SIL Open Font License 1.1.
