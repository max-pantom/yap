#!/usr/bin/env python3
"""Minimal music bed for the 16 s Yap launch film + final mix.

Pure stdlib, deterministic. Run from the repo root:
    python3 design/launch/audio/make_music.py
Reads sfx.wav (runs make_sfx.py first if it is missing) and writes
    music.wav  (music-only stem, already ducked around the big effects)
    mix.wav    (sfx.wav + music.wav, peak <= -1 dBFS, ~ -16 LUFS)
All 48 kHz / 16-bit / stereo / exactly 16.000 s.

Key: A major (A, C#m-ish colours: Amaj9, D, F#m, E), tempo 100 bpm in eighth-notes
(a pulse every 0.300 s), grid offset 0.16 s. Big film beats get their own
exactly-timed accents; grid notes within 70 ms of an accent are dropped.
"""
import math, os, random, struct, subprocess, sys, wave

SR = 48000
NS = 16 * SR
PI = math.pi
random.seed(20261022)
HERE = os.path.dirname(os.path.abspath(__file__))
SFX = os.path.join(HERE, "sfx.wav")
MUSIC = os.path.join(HERE, "music.wav")
MIX = os.path.join(HERE, "mix.wav")

# The music is kept clearly UNDER the effects: music-only loudness is set this many
# LU below the SFX stem (override with YAP_MUSIC_LU_BELOW). Set YAP_MIX_LUFS to
# force a mix loudness instead (that would push the music above the effects).
MUSIC_LU_BELOW = float(os.environ.get("YAP_MUSIC_LU_BELOW", "3.5"))
TARGET_LUFS = os.environ.get("YAP_MIX_LUFS")
STEP = 0.3
T0 = 0.16


def N(s):
    return int(round(s * SR))


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def smooth(x):
    x = 0.0 if x < 0 else 1.0 if x > 1 else x
    return x * x * (3 - 2 * x)


def pan_gains(p):
    a = (p + 1.0) * PI / 4.0
    return math.cos(a) * math.sqrt(2), math.sin(a) * math.sqrt(2)


class Bus:
    def __init__(self):
        self.L = [0.0] * NS
        self.R = [0.0] * NS

    def add(self, t, sl, sr=None, g=1.0, pan=0.0):
        """Add a signal at time t. Mono signal + pan, or explicit stereo."""
        i0 = N(t)
        if sr is None:
            gl, gr = pan_gains(pan)
            sr = sl
        else:
            gl = gr = 1.0
        L, R = self.L, self.R
        for k in range(len(sl)):
            j = i0 + k
            if j >= NS:
                break
            L[j] += sl[k] * g * gl
            R[j] += sr[k] * g * gr


bed = Bus()    # pulse, pad, accents (gets the film's "breath" before 14.85)
fin = Bus()    # the final resolving chord at 14.85


# ---------------------------------------------------------------- voices
def pluck_sig(m, vel, dur=0.7):
    """Soft muted keys: sine + decaying overtones, rounded 3 ms attack."""
    f = mtof(m)
    n = N(dur)
    br = 0.35 + 0.45 * min(vel, 1.2)
    out = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.003)
        p = 2 * PI * f * s
        w = (math.sin(p) + 0.40 * br * math.sin(2 * p) * math.exp(-s / 0.07)
             + 0.16 * br * math.sin(3 * p) * math.exp(-s / 0.035))
        out.append(a * math.exp(-s / 0.20) * w)
    return out


def pluck(bus, t, m, vel, pan, g=0.2, echo=True):
    sig = pluck_sig(m, vel)
    bus.add(t, sig, g=g * vel, pan=pan)
    if echo:  # ping-pong tape-ish echo, dotted (1.5 steps)
        bus.add(t + 0.45, sig, g=g * vel * 0.27, pan=-pan * 0.8 - 0.1 * (1 if pan >= 0 else -1))
        bus.add(t + 0.90, sig, g=g * vel * 0.09, pan=pan * 0.8)


def sub(bus, t, m, g, tau=0.32, dur=1.0):
    f = mtof(m)
    n = N(dur)
    sig = []
    for i in range(n):
        s = i / SR
        a = min(1.0, s / 0.008)
        sig.append(a * math.exp(-s / tau) * (math.sin(2 * PI * f * s) + 0.12 * math.sin(4 * PI * f * s)))
    bus.add(t, sig, g=g)


def shaker(bus, t, g, pan):
    n = N(0.05)
    prev = 0.0
    sig = []
    for i in range(n):
        x = random.gauss(0, 1)
        h = x - prev  # crude highpass
        prev = x
        s = i / SR
        sig.append(min(1.0, s / 0.001) * math.exp(-s / 0.011) * h)
    bus.add(t, sig, g=g, pan=pan)


def brightness(t):
    # filter-opening lift into the dive arrival (2.0 -> 2.55), then stays open
    if t < 2.0:
        return 0.10 + 0.05 * t
    return 0.20 + 0.80 * smooth((t - 2.0) / 0.55)


def pad_note(bus, t0, t1, m, g, att=0.5, rel=0.55, final=False):
    f = mtof(m)
    n = N(t1 - t0 + rel)
    L, R = [], []
    for i in range(n):
        s = i / SR
        t = t0 + s
        a = min(1.0, s / att)
        a = a * a * (3 - 2 * a)
        d = t1 - t0
        r = 1.0 if s < d else max(0.0, 1 - (s - d) / rel)
        e = a * r * g
        b = brightness(t)
        pl = 2 * PI * f * 0.9994 * t
        pr = 2 * PI * f * 1.0006 * t
        L.append(e * (math.sin(pl) + b * 0.32 * math.sin(2 * pl) + b * 0.10 * math.sin(3 * pl)))
        R.append(e * (math.sin(pr) + b * 0.32 * math.sin(2 * pr) + b * 0.10 * math.sin(3 * pr)))
    bus.add(t0, L, R)


# ------------------------------------------------------------- arrangement
# film anchors (seconds): (time, label)
ANCHORS = [
    (2.55, "dive arrival"), (5.05, "whip pan start"), (5.27, "countdown 3"),
    (5.57, "countdown 2"), (5.87, "countdown 1"), (8.20, "whip up"),
    (11.45, "pull back"), (13.75, "flow bar"), (14.85, "logo lands"),
]
ANCH_T = [a[0] for a in ANCHORS]

# chords: (root midi, pad notes, pluck tones in arp order)
A_ = (45, [57, 64, 73], [69, 73, 76, 83])
D_ = (38, [57, 62, 66], [69, 74, 78, 73])
FM = (42, [57, 61, 66], [66, 69, 73, 76])
E_ = (40, [59, 64, 68], [64, 68, 71, 78])
BARS = [A_, A_, D_, FM, D_, E_, E_]          # bars start at T0 + 2.4*k
PATTERN = [0, 2, 1, 3, 2, 1, 3, 2]


def sec_vel(t):
    if t < 0.45:
        return 0.0
    if t < 2.55:
        return 0.22 + 0.30 * (t - 0.45) / 2.1
    if t < 7.25:
        return 1.0
    if t < 8.2:
        return 0.55
    if t < 13.75:
        return 0.85
    return 0.6


# pad bed
for k, (root, padn, _) in enumerate(BARS):
    t0 = T0 + 2.4 * k
    t1 = t0 + 2.4
    for m in padn:
        pad_note(bed, t0, t1, m, 0.055, att=0.55 if k else 0.9)

# pulse grid
k = 0
while True:
    t = T0 + STEP * k
    if t >= 14.2:
        break
    bar = min(int((t - T0) / 2.4), len(BARS) - 1)
    step = k % 8
    root, _, tones = BARS[bar]
    v = sec_vel(t)
    near = any(abs(t - a) < 0.07 for a in ANCH_T)
    if v > 0 and not near:
        acc = 1.0 if step % 4 == 0 else 0.68
        pluck(bed, t, tones[PATTERN[step]], v * acc, 0.28 if step % 2 == 0 else -0.28, g=0.2)
        if step in (0, 3) and t > 1.6:
            sub(bed, t, root, 0.30 * v, tau=0.34 if step == 0 else 0.18)
        if step % 2 == 1 and t > 2.4:
            shaker(bed, t, 0.016 * v, 0.3 if step % 4 == 1 else -0.3)
    k += 1


def stab(bus, t, root, tones, g=1.0, subg=0.5, pan_spread=0.3, gp=0.24):
    sub(bus, t, root, subg * g, tau=0.45, dur=1.2)
    for i, m in enumerate(tones):
        pluck(bus, t, m, 1.15 * g, pan_spread * (1 if i % 2 else -1), g=gp)


stab(bed, 2.55, 33, [69, 73, 76, 83, 88], g=1.0, subg=0.6)
sub(bed, 2.55, 45, 0.28, tau=0.6)
stab(bed, 5.05, 38, [74, 78], g=0.45, subg=0.2)
stab(bed, 5.27, 38, [62, 69, 74, 78], g=1.0, subg=0.62)
stab(bed, 5.57, 40, [64, 71, 76, 80], g=1.0, subg=0.62)
stab(bed, 5.87, 42, [66, 69, 73, 78], g=1.05, subg=0.66)
stab(bed, 8.20, 40, [64, 71, 76, 80, 83], g=0.95, subg=0.55)
stab(bed, 11.45, 38, [62, 69, 74, 78], g=0.9, subg=0.5)
pluck(bed, 13.75, 76, 0.9, -0.2, g=0.24)
pluck(bed, 13.75, 83, 0.8, 0.2, g=0.2)
sub(bed, 13.75, 40, 0.26, tau=0.3)

# final resolving chord on the logo landing: Amaj9 (same key/notes as the sting)
for m, lv, p in [(57, 0.8, 0.0), (64, 0.7, -0.15), (69, 0.7, 0.15), (73, 0.55, -0.2),
                 (76, 0.5, 0.2), (83, 0.25, 0.0)]:
    f = mtof(m)
    n = N(1.15)
    sl, sr_ = [], []
    for i in range(n):
        s = i / SR
        e = min(1.0, s / 0.014) * math.exp(-s / 0.62) * lv
        sl.append(e * (math.sin(2 * PI * f * 0.9995 * s) + 0.2 * math.sin(4 * PI * f * s) * math.exp(-s / 0.2)))
        sr_.append(e * (math.sin(2 * PI * f * 1.0005 * s) + 0.2 * math.sin(4 * PI * f * s) * math.exp(-s / 0.2)))
    fin.add(14.85, sl, sr_, g=0.075)
sub(fin, 14.85, 33, 0.40, tau=0.7, dur=1.15)
sub(fin, 14.85, 45, 0.22, tau=0.5, dur=1.15)
pluck(fin, 14.85, 73, 0.9, -0.2, g=0.16)
pluck(fin, 14.85, 81, 0.7, 0.2, g=0.12)
# fade the final bus to true silence at 16.0
fa = N(0.6)
for i in range(fa):
    w = 0.5 + 0.5 * math.cos(PI * i / fa)
    fin.L[NS - fa + i] *= w
    fin.R[NS - fa + i] *= w

# bed gain: fade-in from silence, "breath" before the logo, tail after it
def bed_gain(t):
    g = smooth(t / 1.0)
    if 14.25 <= t < 14.85:
        g *= 1 - 0.88 * smooth((t - 14.25) / 0.5)
    elif t >= 14.85:
        g *= 0.12 * (1 - smooth((t - 14.85) / 0.45))
    return g


for i in range(NS):
    g = bed_gain(i / SR)
    bed.L[i] *= g
    bed.R[i] *= g

un_L = [bed.L[i] + fin.L[i] for i in range(NS)]   # before ducking
un_R = [bed.R[i] + fin.R[i] for i in range(NS)]

# ducking: (start, end, depth dB)
DUCKS = [
    ("dive riser", 2.00, 2.60, -3.5), ("push-in", 7.25, 7.95, -1.5),
    ("fall + fly-up", 3.50, 4.60, -2.0), ("whip pan + countdown", 5.05, 6.00, -3.0),
    ("whip up", 8.20, 8.55, -3.0), ("pull back", 11.45, 12.10, -2.5),
    ("logo morph", 14.00, 14.85, -2.0), ("sting", 14.85, 15.60, -4.0),
]
target = [1.0] * NS
for _, a, b, db in DUCKS:
    tg = 10 ** (db / 20)
    for i in range(N(a), min(N(b), NS)):
        target[i] = min(target[i], tg)
duck = [1.0] * NS
cur = 1.0
ca = math.exp(-1.0 / (0.025 * SR))
cr = math.exp(-1.0 / (0.18 * SR))
for i in range(NS):
    c = ca if target[i] < cur else cr
    cur = c * cur + (1 - c) * target[i]
    duck[i] = cur
mL = [un_L[i] * duck[i] for i in range(NS)]
mR = [un_R[i] * duck[i] for i in range(NS)]


# --------------------------------------------------------------- loudness
def kw(x):
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


BLK, HOP = N(0.4), N(0.1)


def block_sums(a, b):
    """per-block (sum a^2, sum a*b, sum b^2)/BLK of two K-weighted channels."""
    out = []
    for s in range(0, len(a) - BLK + 1, HOP):
        saa = sab = sbb = 0.0
        for j in range(s, s + BLK):
            x, y = a[j], b[j]
            saa += x * x
            sab += x * y
            sbb += y * y
        out.append((saa / BLK, sab / BLK, sbb / BLK))
    return out


def gated(ms):
    def l(z):
        return -0.691 + 10 * math.log10(z) if z > 0 else -999
    g1 = [z for z in ms if l(z) > -70]
    if not g1:
        return -999.0
    rel = l(sum(g1) / len(g1)) - 10
    g2 = [z for z in g1 if l(z) > rel]
    return l(sum(g2) / len(g2))


def lufs_of(L, R):
    kl, kr = kw(L), kw(R)
    sl, sr_ = block_sums(kl, kl), block_sums(kr, kr)
    return gated([x[0] + y[0] for x, y in zip(sl, sr_)])


def read_wav(p):
    with wave.open(p, "rb") as w:
        assert w.getframerate() == SR and w.getnchannels() == 2 and w.getsampwidth() == 2
        nf = w.getnframes()
        v = struct.unpack("<%dh" % (nf * 2), w.readframes(nf))
    return [x / 32768.0 for x in v[0::2]], [x / 32768.0 for x in v[1::2]]


def write_wav(p, L, R):
    pcm = bytearray()
    for l, r in zip(L, R):
        pcm += struct.pack("<hh", int(round(max(-1, min(1, l)) * 32767)),
                           int(round(max(-1, min(1, r)) * 32767)))
    with wave.open(p, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(pcm))


def soft_limit(x, knee=0.62, ceil=0.885):
    ax = abs(x)
    if ax <= knee:
        return x
    r = ceil - knee
    y = knee + r * math.tanh((ax - knee) / r)
    return y if x > 0 else -y


def db(v):
    return 20 * math.log10(v) if v > 1e-12 else -999.0


# ----------------------------------------------------------- level + mix
if not os.path.exists(SFX):
    subprocess.check_call([sys.executable, os.path.join(HERE, "make_sfx.py")], stdout=subprocess.DEVNULL)
sL, sR = read_wav(SFX)

# search music gain so the mix lands at TARGET_LUFS (music K-weighted once)
ksL, ksR = kw(sL), kw(sR)
kmL, kmR = kw(mL), kw(mR)
SS = [block_sums(ksL, ksL), block_sums(ksR, ksR)]
SM = [block_sums(kmL, kmL), block_sums(kmR, kmR)]
SX = [block_sums(ksL, kmL), block_sums(ksR, kmR)]


def mix_lufs(g):
    ms = []
    for i in range(len(SS[0])):
        z = 0.0
        for c in (0, 1):
            z += SS[c][i][0] + 2 * g * SX[c][i][1] + g * g * SM[c][i][2]
        ms.append(z)
    return gated(ms)


if TARGET_LUFS is None:
    sfx_l = gated([x[0] + y[0] for x, y in zip(SS[0], SS[1])])
    want = sfx_l - MUSIC_LU_BELOW
    mus_l = gated([x[2] + y[2] for x, y in zip(SM[0], SM[1])])
    mg = 10 ** ((want - mus_l) / 20)
else:
    TL = float(TARGET_LUFS)
    lo, hi = 0.02, 20.0
    for _ in range(40):
        mid = math.sqrt(lo * hi)
        if mix_lufs(mid) < TL:
            lo = mid
        else:
            hi = mid
    mg = math.sqrt(lo * hi)
print("music gain applied: %+.2f dB (raw synth units)" % db(mg))

mL = [v * mg for v in mL]
mR = [v * mg for v in mR]
un_L = [v * mg for v in un_L]
un_R = [v * mg for v in un_R]
write_wav(MUSIC, mL, mR)

xL = [soft_limit(sL[i] + mL[i]) for i in range(NS)]
xR = [soft_limit(sR[i] + mR[i]) for i in range(NS)]
write_wav(MIX, xL, xR)

# --------------------------------------------------------------- analysis
print()
for nm, path in [("sfx.wav", SFX), ("music.wav", MUSIC), ("mix.wav", MIX)]:
    with wave.open(path, "rb") as w:
        d, r, c, b = w.getnframes() / w.getframerate(), w.getframerate(), w.getnchannels(), w.getsampwidth() * 8
    L, R = read_wav(path)
    pk = max(max(map(abs, L)), max(map(abs, R)))
    rms = math.sqrt(sum(v * v for v in L + R) / (2 * NS))
    print("%-10s dur %.4f s | %d Hz | %d ch | %d-bit | peak %.2f dBFS | RMS %.2f dBFS | %.1f LUFS"
          % (nm, d, r, c, b, db(pk), db(rms), lufs_of(L, R)))

print("\nmusic anchor onsets (first 2 ms frame to rise above 20% of the local jump, +-60 ms around the film beat):")
H = N(0.002)
eng = []
for i in range(0, NS - H, H):
    eng.append(sum(mL[j] ** 2 + mR[j] ** 2 for j in range(i, i + H)) / H)
bad = 0
for t, lab in ANCHORS:
    c0 = int(t / 0.002)
    base = sorted(eng[c0 - 30:c0 - 5])[len(eng[c0 - 30:c0 - 5]) // 2]
    pk = max(eng[c0 - 5:c0 + 31])
    thr = base + 0.2 * (pk - base)
    bt = next((k + 1) * 0.002 for k in range(c0 - 5, c0 + 31) if eng[k] > thr)
    d = (bt - t) * 1000
    ok = abs(d) <= 20
    bad += 0 if ok else 1
    print("  %-16s film %.2f  music onset %.3f  delta %+5.1f ms %s" % (lab, t, bt, d, "" if ok else "<-- FAIL"))

print("\nducking (music RMS inside window, before vs after duck):")
for nm, a, b, depth in DUCKS:
    i0, i1 = N(a), N(b)
    pre = sum(un_L[j] ** 2 + un_R[j] ** 2 for j in range(i0, i1)) / (i1 - i0)
    post = sum(mL[j] ** 2 + mR[j] ** 2 for j in range(i0, i1)) / (i1 - i0)
    print("  %-22s %5.2f-%5.2f  target %+.1f dB  measured %+.2f dB"
          % (nm, a, b, depth, 10 * math.log10((post + 1e-18) / (pre + 1e-18))))
print("\nmusic first 20 ms peak %.1f dBFS | last 20 ms peak %.1f dBFS" %
      (db(max(max(map(abs, mL[:960])), max(map(abs, mR[:960])))),
       db(max(max(map(abs, mL[-960:])), max(map(abs, mR[-960:]))))))
if bad:
    sys.exit(1)
