#!/usr/bin/env python3
"""Procedural sound-effects track for the 16 s Yap launch film.

Pure stdlib (math, random, struct, wave, array). Deterministic (fixed seed).
Run from the repo root:   python3 design/launch/audio/make_sfx.py
Writes design/launch/audio/sfx.wav (48 kHz / 16-bit / stereo / 16.000 s) and
prints an analysis report (levels, LUFS estimate, per-cue onset check).
"""
import math, os, random, struct, sys, wave

SR = 48000
DUR = 16.0
NS = int(round(DUR * SR))
random.seed(20261021)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "sfx.wav")

PI = math.pi
stems = []  # (name, cue_time, start_idx, L list, R list)


# ----------------------------------------------------------------- helpers
def N(sec):
    return int(round(sec * SR))


def white(n):
    return [random.gauss(0.0, 1.0) for _ in range(n)]


def svf(x, fcs, q=1.0, mode="bp"):
    """TPT state-variable filter, per-sample cutoff list (Hz). Unity-peak bp."""
    k = 1.0 / q
    ic1 = ic2 = 0.0
    out = []
    lim = 0.45 * SR
    for xi, fc in zip(x, fcs):
        g = math.tan(PI * (fc if fc < lim else lim) / SR)
        a1 = 1.0 / (1.0 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
        v3 = xi - ic2
        v1 = a1 * ic1 + a2 * v3
        v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        if mode == "bp":
            out.append(k * v1)
        elif mode == "lp":
            out.append(v2)
        else:
            out.append(xi - k * v1 - v2)
    return out


def sweep(n, f0, f1, curve=1.0):
    r = f1 / f0
    return [f0 * r ** ((i / max(n - 1, 1)) ** curve) for i in range(n)]


def pan_gains(p):
    a = (p + 1.0) * PI / 4.0
    return math.cos(a) * math.sqrt(2), math.sin(a) * math.sqrt(2)


def smooth(x):
    x = 0.0 if x < 0 else 1.0 if x > 1 else x
    return x * x * (3 - 2 * x)


def add_stem(name, t, L, R=None):
    if R is None:
        R = L
    stems.append((name, t, N(t), L, R))


def mono_pan(sig, p=0.0):
    gl, gr = pan_gains(p)
    return [s * gl for s in sig], [s * gr for s in sig]


# ----------------------------------------------------------------- voices
def tick(name, t, f, g, pan=0.0, body=300.0):
    """Soft high-end keyboard tap: tiny noise transient + short tuned knock."""
    n = N(0.05)
    nz = svf(white(n), [f * 1.8] * n, 0.9, "bp")
    sig = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.0004)
        e = (math.exp(-s / 0.0025) * 0.55 * nz[i] * 1.6
             + math.exp(-s / 0.009) * math.sin(2 * PI * f * s) * 0.9
             + math.exp(-s / 0.016) * math.sin(2 * PI * body * s) * 0.45)
        sig.append(a * e * g)
    add_stem(name, t, *mono_pan(sig, pan))


def pop(name, t, f, g, pan=0.0, up=True, dur=0.28, glide=0.055):
    """Rounded pop/bloop: sine with a short pitch glide + soft 2nd harmonic."""
    n = N(dur)
    ph = 0.0
    sig = []
    for i in range(n):
        s = i / SR
        k = math.exp(-s / (glide / 3))
        fi = f * (0.62 + 0.38 * (1 - k)) if up else f * (1 + 0.5 * k)
        ph += 2 * PI * fi / SR
        a = min(1.0, s / 0.0025)
        e = a * math.exp(-s / 0.07)
        sig.append(e * g * (math.sin(ph) + 0.18 * math.sin(2 * ph)))
    add_stem(name, t, *mono_pan(sig, pan))


def whoosh(name, t, dur, fc0, fc1, q, env, g, pan0=0.0, pan1=0.0, curve=1.0,
           width=0.35, tail=0.0, comp=0.5):
    """Airy filtered-noise whoosh. env(x) in [0,1]; pan moves pan0 -> pan1."""
    n = N(dur + tail)
    nd = N(dur)
    sw_ = sweep(nd, fc0, fc1, curve)
    fcs = [sw_[min(i, nd - 1)] for i in range(n)]
    a = svf(white(n), fcs, q, "bp")
    b = svf(white(n), fcs, q, "bp")
    L, R = [], []
    for i in range(n):
        x = min(i / max(nd - 1, 1), 1.0)
        e = env(x)
        if i >= nd:  # exponential tail
            e *= math.exp(-(i - nd) / SR / (tail / 4.0))
        fade_in = min(1.0, i / (0.012 * SR))
        amp = g * e * fade_in * (2000.0 / fcs[i]) ** comp
        gl, gr = pan_gains(pan0 + (pan1 - pan0) * x)
        m, sd = a[i] * 0.7071, b[i] * width
        L.append(amp * (m * gl + sd))
        R.append(amp * (m * gr - sd))
    add_stem(name, t, L, R)


def bell_partial(t0, f, g, tau, att=0.006, detune=0.0):
    return None


# ------------------------------------------------------------------ cues
# envelope shapes (floor keeps onsets audible right at the cue time)
def env_riser(x):
    return 0.05 + 0.95 * x ** 2.4


def env_hump(peak=0.55, floor=0.08):
    def f(x):
        if x < peak:
            return floor + (1 - floor) * math.sin(0.5 * PI * x / peak) ** 1.6
        return math.sin(0.5 * PI * (1 - x) / (1 - peak) + 1e-9) ** 1.4 * (1 - 0.0)
    return f


def env_fall(x):
    return 0.1 + 0.9 * (1 - x) ** 1.5


# ---- word ticks
open_f = [2300, 2050, 2450, 2150]
for t, f in zip([0.12, 0.34, 0.54, 0.74], open_f):
    tick("word tick %.2f" % t, t, f, 0.22, pan=0.0)
for t, f in zip([1.26, 1.44, 1.62], [2250, 2400, 2100]):
    tick("word tick %.2f" % t, t, f, 0.22)

# ---- 0.98 pill pop
pop("pill pop 0.98", 0.98, 400, 0.50, up=True)

# ---- 2.00 -> 2.55 dive through logo: accelerating riser
whoosh("dive riser 2.00-2.55", 2.00, 0.55, 260, 7500, 1.4, env_riser, 0.55,
       curve=1.9, width=0.55, comp=0.35)
# tonal under-riser (very soft)
n = N(0.55)
ph = 0.0
sig = []
for i in range(n):
    x = i / (n - 1)
    ph += 2 * PI * (130 * (1100 / 130) ** (x ** 1.8)) / SR
    sig.append(0.07 * (0.05 + 0.95 * x ** 2.4) * math.sin(ph) * min(1, i / 600.0)
               * (1 if i < n - 300 else (n - i) / 300.0))
add_stem("dive riser tone 2.00-2.55", 2.00, *mono_pan(sig))

# ---- 2.55 bloom (airy, soft, no hard hit)
n = N(1.0)
nz1 = svf(white(n), sweep(n, 4200, 700, 0.5), 0.8, "lp")
nz2 = svf(white(n), sweep(n, 4200, 700, 0.5), 0.8, "lp")
L, R = [], []
for i in range(n):
    s = i / SR
    a = min(1.0, s / 0.014)
    e = a * math.exp(-s / 0.22)
    tone = (math.sin(2 * PI * 220 * s) * 0.5 + math.sin(2 * PI * 329.6 * s) * 0.4
            + math.sin(2 * PI * 440.4 * s) * 0.25) * a * math.exp(-s / 0.30)
    toneR = (math.sin(2 * PI * 220.4 * s) * 0.5 + math.sin(2 * PI * 329.2 * s) * 0.4
             + math.sin(2 * PI * 440.0 * s) * 0.25) * a * math.exp(-s / 0.30)
    L.append(0.30 * e * nz1[i] * 0.55 + 0.11 * tone)
    R.append(0.30 * e * nz2[i] * 0.55 + 0.11 * toneR)
fo = N(0.15)
for i in range(fo):
    L[n - fo + i] *= 1 - i / fo
    R[n - fo + i] *= 1 - i / fo
add_stem("arrival bloom 2.55", 2.55, L, R)

# ---- 2.72..3.42 dictated words (quiet, lower)
for j in range(8):
    t = 2.72 + 0.10 * j
    tick("dictation tick %.2f" % t, t, [1250, 1400, 1180, 1330, 1450, 1210, 1380, 1300][j],
         0.085, pan=(-0.12 if j % 2 else 0.12), body=240)

# ---- 3.50 -> 3.85 fall
whoosh("fall swish 3.50-3.85", 3.50, 0.35, 5200, 380, 1.1, env_fall, 0.30,
       curve=0.7, width=0.30, tail=0.05, comp=0.4)

# ---- 4.15 -> 4.55 sentence flies up (pan centre -> slightly left)
whoosh("fly-up swish 4.15-4.55", 4.15, 0.40, 500, 5600, 1.3,
       env_hump(0.72, 0.10), 0.34, pan0=0.0, pan1=-0.35, curve=1.2, width=0.3,
       comp=0.4)

# ---- 4.55 message sent pop, 4.62 pasted chime
pop("message pop 4.55", 4.55, 620, 0.45, pan=-0.2)


def chime_note(name, t, f, g, pan, tau=0.11):
    n = N(0.4)
    sig = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.003)
        e = a * math.exp(-s / tau)
        sig.append(g * e * (math.sin(2 * PI * f * s) + 0.25 * math.sin(2 * PI * f * 2.0 * s)
                            * math.exp(-s / 0.04)))
    add_stem(name, t, *mono_pan(sig, pan))


chime_note("pasted chime a 4.62", 4.62, 1318.5, 0.17, -0.15)
chime_note("pasted chime b 4.70", 4.70, 1760.0, 0.17, 0.05, 0.14)

# ---- 5.05 -> 5.40 whip pan right -> left
whoosh("whip pan 5.05-5.40", 5.05, 0.35, 700, 3400, 0.9, env_hump(0.45, 0.12),
       0.50, pan0=0.95, pan1=-0.95, curve=0.8, width=0.15, tail=0.12, comp=0.4)

# ---- 5.27 / 5.57 / 5.87 countdown thumps + passing whooshes
for t, f0, p in [(5.27, 78, 0.35), (5.57, 88, -0.35), (5.87, 100, 0.0)]:
    n = N(0.4)
    ph = 0.0
    sig = []
    for i in range(n):
        s = i / SR
        fi = f0 * (0.55 + 0.45 * math.exp(-s / 0.05))
        ph += 2 * PI * fi / SR
        a = min(1.0, s / 0.004)
        sig.append(0.55 * a * math.exp(-s / 0.11) * (math.sin(ph) + 0.12 * math.sin(2 * ph)))
    add_stem("count thump %.2f" % t, t, *mono_pan(sig))
    whoosh("count pass %.2f" % t, t, 0.26, 450, 2600, 1.0, env_hump(0.4, 0.15),
           0.30, pan0=p, pan1=-p, curve=0.9, width=0.3, tail=0.08, comp=0.4)

# ---- 6.15 record blip (two quick soft tones), 6.25 camera bubble pop
for name, t, f in [("record blip a 6.15", 6.15, 880.0), ("record blip b 6.21", 6.21, 1174.7)]:
    n = N(0.12)
    sig = []
    for i in range(n):
        s = i / SR
        sig.append(0.30 * min(1.0, s / 0.003) * math.exp(-s / 0.030) * math.sin(2 * PI * f * s))
    add_stem(name, t, *mono_pan(sig))
pop("camera bubble pop 6.25", 6.25, 500, 0.45, pan=0.2)


# ---- 7.17 mouse click (down + softer release)
def click(name, t, g, f_res, f_body):
    n = N(0.06)
    nzh = svf(white(n), [2500.0] * n, 0.7, "hp")
    nzb = svf(white(n), [f_res] * n, 4.0, "bp")
    sig = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.0002)
        sig.append(g * a * (0.55 * math.exp(-s / 0.0012) * nzh[i]
                            + 1.3 * math.exp(-s / 0.005) * nzb[i]
                            + 0.8 * math.exp(-s / 0.007) * math.sin(2 * PI * f_body * s)))
    add_stem(name, t, *mono_pan(sig))


click("mouse click down 7.17", 7.17, 0.32, 3300, 1000)
click("mouse click up 7.235", 7.235, 0.14, 3900, 1300)

# ---- 7.25 -> 7.90 push-in: low smooth swell
n = N(0.65 + 0.20)
nd = N(0.65)
fcs = [260 + 900 * smooth(min(i / nd, 1)) ** 1.5 for i in range(n)]
a = svf(white(n), fcs, 0.8, "lp")
b = svf(white(n), fcs, 0.8, "lp")
ph = 0.0
L, R = [], []
for i in range(n):
    x = min(i / nd, 1.0)
    e = 0.07 + 0.93 * math.sin(0.5 * PI * x) ** 2.0
    if i >= nd:
        e *= math.exp(-(i - nd) / SR / 0.05)
    e *= min(1.0, i / (0.012 * SR))
    ph += 2 * PI * (52 + 60 * x ** 1.5) / SR
    t_ = 0.34 * e * math.sin(ph)
    L.append(t_ + 0.45 * e * a[i] * 0.5)
    R.append(t_ + 0.45 * e * b[i] * 0.5)
add_stem("push-in swell 7.25-7.90", 7.25, L, R)

# ---- 8.20 -> 8.50 whip pan up
whoosh("whip up 8.20-8.50", 8.20, 0.30, 600, 6000, 1.0, env_hump(0.5, 0.14),
       0.55, pan0=0.1, pan1=-0.1, curve=0.85, width=0.4, tail=0.10, comp=0.4)

# ---- transcript slide-in ticks 8.65 / 9.20 / 9.75
for t, p in [(8.65, -0.2), (9.20, 0.15), (9.75, -0.1)]:
    n = N(0.09)
    fcs = sweep(n, 1400, 4200, 1.0)
    nz = svf(white(n), fcs, 1.4, "bp")
    sig = []
    for i in range(n):
        s = i / SR
        sig.append(0.20 * min(1.0, s / 0.0006) * math.exp(-s / 0.026) * nz[i] * 1.4)
    add_stem("slide-in swish %.2f" % t, t, *mono_pan(sig, p))
    tick("slide-in tick %.2f" % (t + 0.045), t + 0.045, 1900, 0.14, pan=p)
# (the tick above lands after the swish; the swish owns the cue onset)

# ---- 10.35 / 10.51 action-item pops
pop("action pop 10.35", 10.35, 720, 0.30, pan=-0.15, dur=0.2, glide=0.04)
pop("action pop 10.51", 10.51, 850, 0.30, pan=0.15, dur=0.2, glide=0.04)


# ---- 11.00 / 11.25 checkbox ticks
def check(name, t, f, g, pan):
    n = N(0.09)
    nz = svf(white(n), [f * 1.6] * n, 2.5, "bp")
    sig = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.0003)
        sig.append(g * a * (0.9 * math.exp(-s / 0.002) * nz[i] * 1.5
                            + 1.0 * math.exp(-s / 0.016) * math.sin(2 * PI * f * s)
                            + 0.4 * math.exp(-s / 0.03) * math.sin(2 * PI * f * 1.5 * s)))
    add_stem(name, t, *mono_pan(sig, pan))


check("check click 11.00", 11.00, 1700, 0.30, -0.12)
check("check click 11.25", 11.25, 2100, 0.30, 0.12)

# ---- 11.45 -> 12.05 pull-back: airy reverse swell
n = N(0.60 + 0.05)
nd = N(0.60)
fcs = [350 + 3600 * (min(i / nd, 1) ** 1.6) for i in range(n)]
a = svf(white(n), fcs, 0.9, "bp")
b = svf(white(n), fcs, 0.9, "bp")
ph1 = ph2 = 0.0
L, R = [], []
for i in range(n):
    x = min(i / nd, 1.0)
    e = 0.06 + 0.94 * x ** 2.2
    if i >= nd:
        e *= max(0.0, 1 - (i - nd) / (0.05 * SR))
    e *= min(1.0, i / (0.012 * SR))
    comp_ = (2000.0 / fcs[i]) ** 0.4
    ph1 += 2 * PI * (196 * (1 + 0.5 * x)) / SR
    ph2 += 2 * PI * (196.6 * (1 + 0.5 * x)) / SR
    L.append(e * (0.34 * a[i] * comp_ + 0.05 * math.sin(ph1)))
    R.append(e * (0.34 * b[i] * comp_ + 0.05 * math.sin(ph2)))
add_stem("pull-back swell 11.45-12.05", 11.45, L, R)

# ---- 12.20..12.97 tagline-ish words
fs = [1500, 1700, 1400, 1800, 1550, 1650, 1450, 1750]
for j in range(8):
    t = 12.20 + 0.11 * j
    tick("end-card tick %.2f" % t, t, fs[j], 0.095, pan=(-0.1 if j % 2 else 0.1), body=260)

# ---- 13.75 pill pop (centre)
pop("pill pop 13.75", 13.75, 410, 0.50, up=True)

# ---- 14.00 -> 14.85 logo morph: liquid bloops + rising tone
bl = [14.00, 14.12, 14.23, 14.33, 14.42, 14.50, 14.58, 14.65, 14.71, 14.77]
for j, t in enumerate(bl):
    x = j / (len(bl) - 1)
    pop("morph bloop %.2f" % t, t, 300 * (1000 / 300) ** x, 0.20 + 0.14 * x,
        pan=0.25 * math.sin(j * 1.9), dur=0.18, glide=0.05)
n = N(0.85)
ph = 0.0
fcs = sweep(n, 500, 2800, 1.3)
nzm = svf(white(n), fcs, 2.5, "bp")
L, R = [], []
for i in range(n):
    x = i / (n - 1)
    f = 190 * (880 / 190) ** (x ** 1.5)
    f *= 1 + 0.025 * math.sin(2 * PI * 9 * i / SR)  # gentle liquid wobble
    ph += 2 * PI * f / SR
    e = (0.12 + 0.88 * x ** 1.6) * min(1.0, i / 400.0)
    if i > n - N(0.03):
        e *= (n - i) / N(0.03)
    s = 0.075 * e * math.sin(ph) + 0.10 * e * nzm[i] * 1.3
    L.append(s)
    R.append(s * 0.92 + 0.02 * e * math.sin(ph * 1.003))
add_stem("morph glide 14.00-14.85", 14.00, L, R)

# ---- 14.85 brand sting
n = N(1.15)
notes = [  # (freq, level, tau, pan, delay)
    (220.00, 0.50, 0.60, 0.00, 0.000),
    (329.63, 0.38, 0.50, -0.10, 0.012),
    (440.00, 0.40, 0.46, 0.12, 0.020),
    (554.37, 0.30, 0.42, -0.18, 0.030),
    (659.25, 0.28, 0.40, 0.18, 0.040),
    (987.77, 0.14, 0.30, 0.00, 0.052),
]
L = [0.0] * n
R = [0.0] * n
for f, lv, tau, p, dl in notes:
    gl, gr = pan_gains(p)
    d0 = N(dl)
    for i in range(d0, n):
        s = (i - d0) / SR
        a = min(1.0, s / 0.008)
        e = a * math.exp(-s / tau)
        # bell: fundamental + soft inharmonic partials (2.0, 2.76) + tiny detune per ear
        sl = (math.sin(2 * PI * f * s) + 0.22 * math.sin(2 * PI * f * 2.0 * s) * math.exp(-s / 0.18)
              + 0.10 * math.sin(2 * PI * f * 2.76 * s) * math.exp(-s / 0.09))
        sr_ = (math.sin(2 * PI * (f + 0.35) * s) + 0.22 * math.sin(2 * PI * (f * 2.0 + 0.5) * s)
               * math.exp(-s / 0.18) + 0.10 * math.sin(2 * PI * f * 2.76 * s) * math.exp(-s / 0.09))
        L[i] += 0.52 * lv * e * sl * (0.6 + 0.4 * gl)
        R[i] += 0.52 * lv * e * sr_ * (0.6 + 0.4 * gr)
# warm low body
for i in range(n):
    s = i / SR
    a = min(1.0, s / 0.010)
    b = a * (math.exp(-s / 0.55) * 0.55 * math.sin(2 * PI * 110 * s)
             + math.exp(-s / 0.40) * 0.25 * math.sin(2 * PI * 55 * s))
    L[i] += 0.55 * b
    R[i] += 0.55 * b
# airy shimmer on the attack
nzs = svf(white(n), [5500.0] * n, 0.7, "hp")
nzs2 = svf(white(n), [5500.0] * n, 0.7, "hp")
for i in range(min(n, N(0.4))):
    s = i / SR
    e = min(1.0, s / 0.004) * math.exp(-s / 0.07)
    L[i] += 0.035 * e * nzs[i]
    R[i] += 0.035 * e * nzs2[i]
# decay to true silence at 16.000 s (stem ends exactly at 16.0)
fa = N(0.55)
for i in range(fa):
    w = 0.5 + 0.5 * math.cos(PI * i / fa)
    L[n - fa + i] *= w
    R[n - fa + i] *= w
L[-1] = R[-1] = 0.0
add_stem("brand sting 14.85", 14.85, L, R)

# ---- 14.95 / 15.20 tagline ticks (under the sting)
tick("tagline tick 14.95", 14.95, 1650, 0.10, pan=-0.1, body=250)
tick("tagline tick 15.20", 15.20, 1800, 0.10, pan=0.1, body=250)

# ----------------------------------------------------------------- mix
mixL = [0.0] * NS
mixR = [0.0] * NS
for name, t, i0, L, R in stems:
    for k in range(len(L)):
        j = i0 + k
        if j >= NS:
            break
        mixL[j] += L[k]
        mixR[j] += R[k]

# quiet room bed (~ -50 dBFS RMS, lowpassed, faded at the edges)
bedL = svf(white(NS), [900.0] * NS, 0.7, "lp")
bedR = svf(white(NS), [900.0] * NS, 0.7, "lp")
bed_gain = 0.0  # scaled after normalisation (see below)


def kweight(x):
    # ITU-R BS.1770 K-weighting at 48 kHz
    def bq(x, b, a):
        z1 = z2 = 0.0
        y = []
        for v in x:
            o = b[0] * v + z1
            z1 = b[1] * v - a[1] * o + z2
            z2 = b[2] * v - a[2] * o
            y.append(o)
        return y
    y = bq(x, [1.53512485958697, -2.69169618940638, 1.19839281085285],
           [1.0, -1.69065929318241, 0.73248077421585])
    return bq(y, [1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])


def lufs(L, R):
    kl, kr = kweight(L), kweight(R)
    blk, hop = N(0.4), N(0.1)
    ms = []
    for s in range(0, len(kl) - blk + 1, hop):
        zl = sum(v * v for v in kl[s:s + blk]) / blk
        zr = sum(v * v for v in kr[s:s + blk]) / blk
        ms.append(zl + zr)
    def l(z):
        return -0.691 + 10 * math.log10(z) if z > 0 else -999
    g1 = [z for z in ms if l(z) > -70]
    if not g1:
        return -999.0
    rel = l(sum(g1) / len(g1)) - 10
    g2 = [z for z in g1 if l(z) > rel]
    return l(sum(g2) / len(g2))


def soft_limit(x, knee=0.62, ceil=0.885):
    ax = abs(x)
    if ax <= knee:
        return x
    r = ceil - knee
    y = knee + r * math.tanh((ax - knee) / r)
    return y if x > 0 else -y


# choose a global gain: aim near -15 LUFS-ish with the soft limiter holding
# the peak under -1 dBFS (ceil 0.885 = -1.06 dBFS). Sparse SFX tracks cannot
# reach -15 LUFS without squashing, so we settle for the highest gain that
# keeps the brand sting the loudest moment and the limiter nearly transparent.
PRE_GAIN = float(os.environ.get("YAP_PRE_GAIN", "1.0"))
sting_raw = max(max(abs(v) for v in mixL[N(14.85):N(15.2)]), max(abs(v) for v in mixR[N(14.85):N(15.2)]))
GLOBAL = PRE_GAIN * 0.84 / sting_raw  # sting peak -> ~0.84 (-1.5 dBFS); it is the loudest moment
if os.environ.get("YAP_DEBUG"):
    for nm, t, i0, L, R in sorted(stems, key=lambda s: -max(max(map(abs, s[3])), max(map(abs, s[4])))) [:14]:
        print("  peak %.3f  %s" % (GLOBAL * max(max(map(abs, L)), max(map(abs, R))), nm))

bed_rms_target = 10 ** (-50 / 20)
rb = math.sqrt(sum(v * v for v in bedL) / NS)
bed_gain = bed_rms_target / rb
for i in range(NS):
    t = i / SR
    bf = smooth(t / 0.5) * smooth((DUR - t) / 0.6)
    mixL[i] = mixL[i] * GLOBAL + bedL[i] * bed_gain * bf
    mixR[i] = mixR[i] * GLOBAL + bedR[i] * bed_gain * bf
    mixL[i] = soft_limit(mixL[i])
    mixR[i] = soft_limit(mixR[i])

# ----------------------------------------------------------------- write
pcm = bytearray()
for i in range(NS):
    l = int(round(max(-1.0, min(1.0, mixL[i])) * 32767))
    r = int(round(max(-1.0, min(1.0, mixR[i])) * 32767))
    pcm += struct.pack("<hh", l, r)
with wave.open(OUT, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(bytes(pcm))

# --------------------------------------------------------------- analysis
def dbfs(v):
    return 20 * math.log10(v) if v > 1e-12 else -999.0


with wave.open(OUT, "rb") as w:
    ch, sw, fr, nf = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(nf)
vals = struct.unpack("<%dh" % (nf * ch), raw)
aL = [v / 32768.0 for v in vals[0::2]]
aR = [v / 32768.0 for v in vals[1::2]]
peak = max(max(abs(v) for v in aL), max(abs(v) for v in aR))
rms = math.sqrt(sum(v * v for v in aL + aR) / (2 * nf))
print("file: %s" % OUT)
print("duration %.4f s | rate %d | channels %d | bits %d" % (nf / fr, fr, ch, sw * 8))
print("peak %.2f dBFS | RMS %.2f dBFS | integrated LUFS (BS.1770 est.) %.1f"
      % (dbfs(peak), dbfs(rms), lufs(aL, aR)))
print("bed RMS target -50 dBFS (fades in/out)")
sting_pk = max(abs(v) for v in aL[N(14.85):N(15.2)] + aR[N(14.85):N(15.2)])
others_pk = max(abs(v) for v in aL[:N(14.8)] + aR[:N(14.8)])
print("sting peak %.2f dBFS | loudest earlier moment %.2f dBFS" % (dbfs(sting_pk), dbfs(others_pk)))
print("last 20 ms peak: %.1f dBFS (silence by 16.0)" % dbfs(max(abs(v) for v in aL[-960:] + aR[-960:])))

# per-cue onset check
THR = 10 ** (-62 / 20)
print("\n%-34s %8s %10s %9s %s" % ("cue (stem)", "cue t", "onset t", "delta ms", "mix +dB"))
bad = 0
for name, t, i0, L, R in stems:
    gl = GLOBAL
    first = None
    for k in range(len(L)):
        if max(abs(L[k]), abs(R[k])) * gl > THR:
            first = k
            break
    on = (i0 + first) / SR if first is not None else None
    d = (on - t) * 1000 if on is not None else None
    # mix rise: RMS 15 ms after vs 15 ms before the cue
    a0, a1, a2 = N(t) - N(0.015), N(t), N(t) + N(0.015)
    pre = sum(aL[j] ** 2 + aR[j] ** 2 for j in range(max(a0, 0), a1)) / max(N(0.015), 1)
    post = sum(aL[j] ** 2 + aR[j] ** 2 for j in range(a1, min(a2, nf))) / N(0.015)
    rise = 10 * math.log10((post + 1e-12) / (pre + 1e-12))
    ok = d is not None and -15 <= d <= 15
    if not ok:
        bad += 1
    print("%-34s %8.3f %10.4f %+9.2f %+6.1f %s"
          % (name, t, on if on else -1, d if d is not None else 0, rise, "" if ok else "  <-- FAIL"))
print("\nstems: %d | onset failures: %d" % (len(stems), bad))
if bad:
    sys.exit(1)
