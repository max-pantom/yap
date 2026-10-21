# Yap launch film: SFX, music and mix

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

## SFX level (revision 2)

All effects are trimmed -4 dB; the brand sting only -2.5 dB so the ending still lands.
Measured: peak -4.0 dBFS, about -21.5 LUFS (own BS.1770 estimate), sting is the loudest
moment. All 72 elements start within 0 to 5 ms of their cue time.

## Music bed: `make_music.py` -> `music.wav`, `mix.wav`

A minimal warm pulse, no melody: muted electric-keys plucks arpeggiating each chord
with a soft ping-pong echo, a light sub on steps 1 and 4 of each bar, a barely-there
shaker on off-beats, and a slow detuned sine pad that "opens" (gets brighter) from
2.0 to 2.55 into the dive. Key A major, chords Amaj9 / D / F#m / E, resolving to the
same Amaj9 as the sting at 14.85. Tempo 100 bpm in eighth notes (a step every 0.300 s,
grid offset 0.16 s, 8-step bars). Starts from true silence with a 1 s fade-in.

Film beats get exactly-timed accents (grid notes within 70 ms are dropped):
2.55 chord stab + sub (arrival), 5.05 small anticipation, 5.27 / 5.57 / 5.87 rising
D, E, F#m stabs with sub (countdown), 8.20 E stab, 11.45 D stab, 13.75 two-note pluck,
14.85 Amaj9 chord with low body decaying to silence by 16.0. The bed pulls back
(breath, to 12 percent) from 14.25 to 14.80 and the pulse stops at 14.2.

Ducking (smooth, 25 ms attack / 180 ms release): riser -3.5 dB, fall + fly-up -2,
whip pan + countdown -3, push-in -1.5, whip up -3, pull back -2.5, logo morph -2, sting -4.

Levels (measured): music-only about -25 LUFS (3.5 LU under the effects), peak -8.3 dBFS;
mix.wav about -20.6 LUFS, peak -2.9 dBFS. Music onsets land 4 to 6 ms after each film beat.
`mix.wav` = `sfx.wav` + `music.wav` (soft limiter only as a safety). The coordinator's -16 LUFS mix target
conflicts with "effects 4 dB quieter and music clearly under them"; reaching it would
need the music louder than the effects (`YAP_MIX_LUFS=-16`) or a master gain of
about +4.6 dB, which undoes the SFX reduction. Left at the quieter, music-under balance;
a master gain of up to about +1.8 dB keeps the peak under -1 dBFS.

Re-run (in order, from the repo root):

    python3 design/launch/audio/make_sfx.py
    python3 design/launch/audio/make_music.py

`make_music.py` reads `sfx.wav` (it runs `make_sfx.py` itself if the file is missing),
writes `music.wav` and `mix.wav`, and prints duration, rate, peak, RMS and LUFS for all
three files, the music-onset check, and the ducking depths (about 25 s).
Env knobs: `YAP_MUSIC_LU_BELOW` (default 3.5), `YAP_MIX_LUFS` (force a mix loudness).
