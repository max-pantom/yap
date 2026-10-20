# Launch film

A 16-second, 1920×1080 launch video for Yap 1.1, in the look of [yap.primitive8.cc](https://yap.primitive8.cc):
white paper, Geist, the grey `#e8e8ed` demo panels and the live Yap mark (Yap's own `mark-config.json` values).

| Time | Scene |
|---|---|
| 0–2.4 s | The mark rolls in · "Less typing. More yapping." |
| 2.4–6 s | Just say it: the Flow bar hears "ship it thursday at 3, no wait, 4" and pastes "Ship it Thursday at 4." |
| 6–9.2 s | Show, don't tell: countdown, camera bubble, a click and an auto-zoom |
| 9.2–12.4 s | Every call, noted (new): You and Others, then action items ticked off |
| 12.4–14 s | No account. No cloud. All on your Mac. |
| 14–16 s | Got something to say? · Download for Mac · yap.primitive8.cc |

Every frame is drawn by `draw(t)` in `launch.html`, so the preview and the export are identical.

```bash
node design/launch/serve.mjs     # then open http://127.0.0.1:3010 and press Export MP4
```

Export encodes frame by frame (WebCodecs + mp4-muxer) and saves `out/yap-launch.mp4` and a poster frame,
`out/yap-launch-poster.png`. The film is silent; add music in your editor of choice.

The Geist fonts in `fonts/` are © Vercel, under the SIL Open Font License 1.1.
