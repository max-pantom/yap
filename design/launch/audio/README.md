# Yap launch film: SFX track

`sfx.wav` is 48 kHz, 16-bit, stereo, exactly 16.000 s. Everything is synthesized
procedurally by `make_sfx.py` (Python 3 standard library only, fixed random seed,
so the output is byte-identical on every run).

## Re-run

From the repo root:

    python3 design/launch/audio/make_sfx.py

It rewrites `design/launch/audio/sfx.wav` and prints an analysis (duration, peak,
RMS, estimated LUFS, and a per-cue onset check; exit code 1 if any cue onset is
more than 15 ms off). Takes about 8 seconds.

## Building blocks

- **Tick**: ~1 ms band-passed noise transient + short tuned sine knock (1.1 to 2.5 kHz) + low body sine.
- **Pop**: sine with a fast pitch glide (up for "bloop", down for none) + faint 2nd harmonic, ~70 ms decay.
- **Whoosh**: state-variable band-pass filtered noise with a swept cutoff and amplitude shape, two decorrelated noise streams for width, equal-power pan along the motion.
- **Click**: noise highpass burst + resonant band-pass + short body sine.
- **Bed**: -50 dBFS lowpassed room tone, faded in and out.

## Cue list

| Time (s) | Sound | Made of |
|---|---|---|
| 0.12, 0.34, 0.54, 0.74 | word ticks | tick, 2.0 to 2.5 kHz, slightly different pitch each |
| 0.98 | Flow pill pop | rising-glide pop, 400 Hz |
| 1.26, 1.44, 1.62 | word ticks | tick |
| 2.00 to 2.55 | dive through logo | band-pass noise riser 260 Hz to 7.5 kHz (accelerating curve, wide stereo) + quiet rising sine |
| 2.55 | arrival bloom | lowpassed noise falling 4.2 kHz to 700 Hz, ~0.8 s decay, with a very soft A/E pad (no hit) |
| 2.72 to 3.42 (x8) | dictated words | quiet low ticks (1.2 to 1.45 kHz), tiny L/R alternation |
| 3.50 to 3.85 | words fall away | descending noise swish 5.2 kHz to 380 Hz |
| 4.15 to 4.55 | sentence flies up | rising swish 500 Hz to 5.6 kHz, pan centre to slightly left |
| 4.55 | message sent | pop, 620 Hz |
| 4.62 / 4.70 | "Pasted" | two-note chime E6 then A6, short |
| 5.05 to 5.40 | whip pan left | fast noise whoosh, pan hard right to hard left |
| 5.27, 5.57, 5.87 | countdown 3, 2, 1 | soft sub thump (78/88/100 Hz) + short passing whoosh crossing the field |
| 6.15 / 6.21 | record blip | two soft sine tones (880, 1175 Hz) |
| 6.25 | camera bubble | pop, 500 Hz |
| 7.17 (+7.235) | mouse click | crisp down click plus a quieter release |
| 7.25 to 7.90 | push-in | low swell: rising 52 to 112 Hz sine + lowpassed noise |
| 8.20 to 8.50 | whip up | fast rising whoosh 600 Hz to 6 kHz |
| 8.65, 9.20, 9.75 | transcript lines | short rising swish + a soft tick 45 ms later |
| 10.35, 10.51 | action items | light pops, 720 / 850 Hz |
| 11.00, 11.25 | checkboxes | crisp check clicks (1.7 / 2.1 kHz) |
| 11.45 to 12.05 | pull back | reverse-style airy swell, band-pass noise rising + faint pad |
| 12.20 to 12.97 (x8) | "No account. No cloud..." | very soft ticks |
| 13.75 | pill pop (centre) | pop, 410 Hz |
| 14.00 to 14.85 | logo morph | 10 accelerating bloops rising 300 Hz to 1 kHz + gliding sine with gentle wobble + band-pass noise |
| 14.85 | brand sting | warm Amaj add-style bell chord (A3 E4 A4 C#5 E5 B5), soft 110/55 Hz body, air on the attack; faded to silence at 16.0 |
| 14.95, 15.20 | tagline ticks | two very soft ticks under the sting |

## Last measured values

Peak -1.9 dBFS, RMS about -22 dBFS, about -18 LUFS (own BS.1770 estimate, sparse
material), brand sting is the loudest moment. All 72 sound elements start within
1 to 5 ms of their cue time (checked against each element's own signal at -62 dBFS).
