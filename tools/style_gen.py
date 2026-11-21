"""Generate the "in the style of" wavetable banks (AMB, BLO, PPG, VS).

These are ORIGINAL, procedurally generated single-cycle waves. They imitate the *character*
of the instruments named in the bank names (what kinds of sweeps, formants, stair-stepped
8-bit digital timbres, additive/FM textures those instruments are known for). They are not
dumps or copies of any instrument's ROM data.

Output: 8 files x 128 waves (16 tables of 8 waves), 257 frames per wave (256 + wrap point),
16-bit mono, 48 kHz, same layout as the Sheep/Plaits files.

    python3 tools/style_gen.py waves/            # writes the wavs
    python3 tools/style_gen.py waves/ --docs docs/wavetable-tables.md
"""
import sys, os, wave
import numpy as np

N = 256
K = np.arange(1, 97, dtype=np.float64)          # harmonic numbers used (<= 96, below N/2)
TH = np.arange(N) / N
VOWELS = {'a': (730, 1090, 2440), 'e': (530, 1840, 2480), 'i': (270, 2290, 3010),
          'o': (570, 840, 2410), 'u': (300, 870, 2240)}

# ---------------------------------------------------------------- building blocks
def norm(w):
    w = np.asarray(w, dtype=np.float64)
    w = w - w.mean()
    m = np.abs(w).max()
    return w / m * 0.95 if m > 1e-9 else w

def from_amps(a, ph=None):
    """sum of sines with harmonic amplitudes a[0]=h1 ..."""
    n = min(len(a), N // 2 - 1)
    spec = np.zeros(N // 2 + 1, complex)
    p = np.zeros(n) if ph is None else np.asarray(ph)[:n]
    spec[1:n + 1] = np.asarray(a)[:n] * np.exp(1j * (p - np.pi / 2)) * (N / 2)
    return np.fft.irfft(spec, N)

def band(w, kmax=100):
    spec = np.fft.rfft(w)
    spec[kmax + 1:] = 0
    return np.fft.irfft(spec, N)

saw = lambda k: 1 / k
odd = lambda k: np.where(k % 2 == 1, 1 / k, 0.0)
tri = lambda k: np.where(k % 2 == 1, 1 / k ** 2, 0.0)
lerp = lambda a, b, u: a + (b - a) * u
def geo(a, b, u): return a * (b / a) ** u

def reso(base, c, Q):                 # 2-pole resonant low-pass magnitude, c = harmonic number
    x = K / c
    return base(K) / np.sqrt((1 - x * x) ** 2 + (x / Q) ** 2)
def lowp(base, c, order=2): return base(K) / np.sqrt(1 + (K / c) ** (2 * order))
def highp(base, c, order=2):
    x = (K / c) ** order
    return base(K) * x / np.sqrt(1 + x * x)
def peak(c, w): return np.exp(-0.5 * ((K - c) / w) ** 2)

def formant_amps(fs, f0, q=7.0, tilt=1.3):
    a = np.zeros_like(K)
    for i, f in enumerate(fs):
        c = max(f / f0, 1.2)
        a += reso(lambda k: k ** -tilt, c, q) * (0.55 ** i) * c ** 0.0
    return a

def vowel_path(seq, u, f0, q=7.0):
    """morph through a sequence of vowels as u goes 0..1"""
    s = u * (len(seq) - 1)
    i = min(int(s), len(seq) - 2)
    t = s - i
    fa, fb = VOWELS[seq[i]], VOWELS[seq[i + 1]]
    fs = [lerp(x, y, t) for x, y in zip(fa, fb)]
    return from_amps(formant_amps(fs, f0, q))

def rnd_spec(seed, tilt=1.0, sparse=0.0, n=64):
    r = np.random.RandomState(seed)
    a = r.uniform(0.0, 1.0, n) ** 2 * np.arange(1, n + 1, dtype=float) ** -tilt
    a[r.uniform(size=n) < sparse] = 0
    a[0] = max(a[0], 0.4 * a.max())
    ph = r.uniform(0, 2 * np.pi, n)
    return a, ph

def spec_morph(seedA, seedB, u, tilt=1.0, sparse=0.0):
    aA, pA = rnd_spec(seedA, tilt, sparse); aB, pB = rnd_spec(seedB, tilt, sparse)
    return from_amps(lerp(aA, aB, u), lerp(pA, pB, u))

def sinfold(u, g0, g1, shape=np.sin):
    g = lerp(g0, g1, u)
    x = shape(2 * np.pi * TH) * g
    return band(((x + 1) % 4 - 2).clip(-1, 1) * 0 + np.where(np.abs(x) <= 1, x, 2 * np.sign(x) - x) * 0 + fold(x), 100)

def fold(x):
    # triangle-wave folding into [-1, 1]
    return 2 * np.abs(((x + 1) / 2) % 2 - 1) - 1 if False else np.interp(((x + 1) % 4), [0, 1, 3, 4], [-1 + 0, 0 + 0, 0, 1]) * 0 + (1 - np.abs(((x + 1) % 4) - 2)) * -1 + 0

def tfold(x):
    """reflect x into [-1,1] (wavefolder)"""
    y = (x + 1) % 4
    return np.where(y < 2, y - 1, 3 - y)

def fm(u, ratio, imax):
    I = u * imax
    return band(np.sin(2 * np.pi * TH + I * np.sin(2 * np.pi * ratio * TH)), 100)

def fold_sine(u, g0, g1):
    return band(tfold(np.sin(2 * np.pi * TH) * lerp(g0, g1, u)), 100)

def fold_tri(u, g0, g1):
    t = 1 - 4 * np.abs(TH - 0.25) if False else np.where(TH < 0.5, 4 * TH - 1, 3 - 4 * TH)
    return band(tfold(t * lerp(g0, g1, u)), 100)

def sync_wave(u, r0, r1, slave='saw'):
    r = lerp(r0, r1, u)
    ph = (TH * r) % 1.0
    w = (2 * ph - 1) if slave == 'saw' else np.sin(2 * np.pi * ph)
    return band(w * (1 - 0.5 * TH) , 100)

def pwm(u, w0, w1):
    w = lerp(w0, w1, u)
    a = np.sin(np.pi * K * w) / K
    return from_amps(a, -np.pi * K * w + np.pi * 0.5 - np.pi * 0.5)   # centred pulse

def comb(u, n0, n1, base=saw):
    n = int(round(lerp(n0, n1, u)))
    if base is odd: n |= 1          # an even divisor would leave only even harmonics, which odd() zeroes
    return from_amps(np.where(K % n == 0, base(K), 0.0))

def oddeven(u, base=saw):
    return from_amps(np.where(K % 2 == 0, base(K) * u, base(K) * (1 - u) + 0.05 * base(K)))

def buzz(u, n0, n1):
    n = lerp(n0, n1, u)
    a = np.clip(n - K + 1, 0, 1)
    return from_amps(a)

def ring(u, r0, r1):
    r = lerp(r0, r1, u)
    return band(np.sin(2 * np.pi * TH) * np.sin(2 * np.pi * r * TH) + 0.3 * np.sin(2 * np.pi * TH), 100)

def drawbars(u, A, B):
    harm = [1, 2, 3, 4, 6, 8, 10, 12, 16]
    a = np.zeros_like(K)
    for h, wa, wb in zip(harm, A, B):
        a[h - 1] = lerp(wa, wb, u)
    return from_amps(a)

def partials(u, ks, wa, wb, decay=0.0):
    a = np.zeros_like(K)
    for k, x, y in zip(ks, wa, wb):
        a[k - 1] = lerp(x, y, u) * np.exp(-decay * k)
    return from_amps(a)

def glass(u, c0, c1, width=1.2):
    c = lerp(c0, c1, u)
    return from_amps(peak(c, width) + 0.5 * peak(2 * c, width) + 0.15 * peak(1, 0.6))

def saw_tri(u): return from_amps(lerp(saw(K), tri(K) * 1.0, u))
def saw_pulse(u): return from_amps(lerp(saw(K), odd(K), u))
def harm_count(u, n0, n1, base=saw):
    n = lerp(n0, n1, u)
    return from_amps(base(K) * np.clip(n - K + 1, 0, 1))

def tampura(u):
    c = 6 + 8 * u
    return from_amps(K ** -0.5 * (0.25 + peak(c, 3.0) + 0.7 * peak(c * 1.7, 2.5)), np.where(K % 2 == 0, 0.6, 0.0) * u)

def ppg(w, hold=4, bits=8):
    """PPG-style: 64 samples per cycle, 8-bit, stair-stepped"""
    w = norm(w)
    s = w[hold // 2::hold]
    q = np.round(s * (2 ** (bits - 1) - 1)) / (2 ** (bits - 1) - 1)
    return np.repeat(q, hold)

def R(base, c0, c1, Q, rev=False):
    return lambda u: from_amps(reso(base, geo(c0, c1, 1 - u if rev else u), Q))
def LP(base, c0, c1, o=2): return lambda u: from_amps(lowp(base, geo(c0, c1, u), o))
def HP(base, c0, c1, o=2): return lambda u: from_amps(highp(base, geo(c0, c1, u), o))
def V(seq, f0, q=7.0): return lambda u: vowel_path(seq, u, f0, q)
def S2(a, b, tilt=1.0, sparse=0.0): return lambda u: spec_morph(a, b, u, tilt, sparse)
def twin(u0, u1, Q): return lambda u: from_amps(reso(saw, geo(u0, u1, u), Q) + 0.8 * reso(saw, 2.7 * geo(u0, u1, u), Q))
def stair(f, hold=4, bits=8): return lambda u: ppg(f(u), hold, bits)

# ---------------------------------------------------------------- the banks
BANKS = {}

BANKS['ambika_1'] = ('AMB A: resonant sweeps and vocal/string categories', [
    ('saw resonant sweep (Q3)', R(saw, 1.5, 30, 3)), ('saw resonant sweep (Q10)', R(saw, 1.5, 36, 10)),
    ('pulse resonant sweep', R(odd, 1.5, 30, 6)), ('triangle resonant sweep', R(tri, 2, 40, 12)),
    ('reverse resonant sweep', R(saw, 1.5, 34, 6, rev=True)), ('twin peaks', twin(1.2, 12, 8)),
    ('saw low-pass sweep', LP(saw, 40, 1.2)), ('saw high-pass sweep', HP(saw, 1, 30)),
    ('male vowels a-e-i-o-u', V('aeiou', 110)), ('female vowels a-e-i-o-u', V('aeiou', 220)),
    ('choir', V('uoaei', 165, 3.0)), ('tampura-like buzz', tampura),
    ('bowed string', lambda u: from_amps(reso(saw, 3 + 10 * u, 2.5))),
    ('vibes-like partials', lambda u: partials(u, [1, 4, 10], [1, .3, .1], [1, .8, .6], 0.01)),
    ('electric piano tines', lambda u: partials(u, [1, 2, 3, 4, 5, 7], [1, .5, .2, .1, .05, .0], [1, .9, .5, .4, .2, .3])),
    ('drawbar organ', lambda u: drawbars(u, [1, .8, .2, 0, 0, 0, 0, 0, 0], [.6, 1, .8, .8, .5, .6, .3, .5, .3]))])

BANKS['ambika_2'] = ('AMB B: basic waves, folds, sync and digital shapes', [
    ('saw to triangle', saw_tri), ('pulse width sweep', lambda u: pwm(u, 0.5, 0.06)),
    ('saw to pulse', saw_pulse), ('sine to saw (harmonic count)', lambda u: harm_count(u, 1, 40)),
    ('sine fold', lambda u: fold_sine(u, 0.9, 5)), ('triangle fold', lambda u: fold_tri(u, 0.9, 5)),
    ('saw sync sweep', lambda u: sync_wave(u, 1, 6)), ('sine sync sweep', lambda u: sync_wave(u, 1, 8, 'sine')),
    ('harmonic comb', lambda u: comb(u, 1, 8)), ('odd / even blend', oddeven),
    ('buzz', lambda u: buzz(u, 1, 48)), ('ring modulation', lambda u: ring(u, 1, 5)),
    ('FM 1:1', lambda u: fm(u, 1, 6)), ('FM 1:2', lambda u: fm(u, 2, 6)), ('FM 1:3', lambda u: fm(u, 3, 5)),
    ('random spectra', S2(11, 12, 1.0, 0.3))])

BANKS['blofeld_1'] = ('BLO A: digital, FM and evolving spectra', [
    ('FM 1:4 sweep', lambda u: fm(u, 4, 8)), ('FM 1:5 sweep', lambda u: fm(u, 5, 7)),
    ('FM 1:7 metallic', lambda u: fm(u, 7, 6)), ('deep sine fold', lambda u: fold_sine(u, 1, 9)),
    ('saw sync sweep (wide)', lambda u: sync_wave(u, 1, 12)), ('sine sync sweep (wide)', lambda u: sync_wave(u, 1, 14, 'sine')),
    ('evolving spectra 1', S2(21, 22, 1.0)), ('evolving spectra 2', S2(23, 24, 1.3)),
    ('evolving spectra 3 (sparse)', S2(25, 26, 0.8, 0.5)), ('evolving spectra 4 (bright)', S2(27, 28, 0.5)),
    ('formant sweep', lambda u: from_amps(reso(saw, 1.5 + 18 * u, 8) + reso(saw, 3 + 30 * u, 8) * 0.5)),
    ('notch sweep', lambda u: from_amps(saw(K) * (1 - peak(geo(2, 40, u), 1.5)))),
    ('comb (odd harmonics)', lambda u: comb(u, 1, 9, odd)), ('ring (wide)', lambda u: ring(u, 1, 9)),
    ('triangle fold (deep)', lambda u: fold_tri(u, 1, 10)), ('buzz (bright)', lambda u: buzz(u, 4, 80))])

BANKS['blofeld_2'] = ('BLO B: vocal, organ, bells and pads', [
    ('vowels a-o-u', V('aou', 120, 8)), ('vowels i-e-a', V('iea', 120, 8)),
    ('vowels (female) e-i-o', V('eio', 240, 6)), ('vowels (choir) u-a-i', V('uai', 180, 3.5)),
    ('organ 1', lambda u: drawbars(u, [1, 1, 1, 0, 0, 0, 0, 0, 0], [1, 0, .8, 0, .6, 0, .4, 0, .3])),
    ('organ 2 (percussive)', lambda u: drawbars(u, [1, .2, 0, 0, 0, 0, 0, 0, 0], [.5, 1, 1, .7, .8, .9, .6, .8, .5])),
    ('bells', lambda u: partials(u, [1, 2, 3, 5, 7, 9, 11], [1, .1, .5, .2, .1, .05, .02], [1, .7, .3, .6, .5, .4, .3], 0.01)),
    ('glass', lambda u: glass(u, 3, 14)), ('pad (soft)', S2(31, 32, 2.0)), ('pad (airy)', S2(33, 34, 1.6, 0.4)),
    ('strings-ish', lambda u: from_amps(reso(saw, 2 + 12 * u, 1.6))),
    ('bright saw to dark saw', lambda u: from_amps(lowp(saw, geo(40, 2, u), 1))),
    ('hollow (pulse sweep)', lambda u: pwm(u, 0.5, 0.15)), ('reed', lambda u: from_amps(odd(K) * reso(saw, 4 + 8 * u, 3) * 0 + reso(odd, 4 + 8 * u, 3))),
    ('metallic partials', lambda u: partials(u, [1, 3, 4, 6, 8, 11, 13], [1, .6, .3, .5, .2, .1, .1], [.4, 1, .8, .3, .7, .6, .5])),
    ('random spectra (dark)', S2(35, 36, 1.8))])

BANKS['ppg_1'] = ('PPG A: stair-stepped 8-bit sweeps (64 samples per cycle)', [
    ('resonant sweep', stair(R(saw, 1.5, 20, 5))), ('resonant sweep (pulse)', stair(R(odd, 1.5, 20, 5))),
    ('low-pass sweep', stair(LP(saw, 30, 1.3))), ('high-pass sweep', stair(HP(saw, 1, 20))),
    ('pulse width sweep', stair(lambda u: pwm(u, 0.5, 0.08))), ('saw sync sweep', stair(lambda u: sync_wave(u, 1, 5))),
    ('sine sync sweep', stair(lambda u: sync_wave(u, 1, 6, 'sine'))), ('harmonic comb', stair(lambda u: comb(u, 1, 6))),
    ('odd / even blend', stair(oddeven)), ('buzz', stair(lambda u: buzz(u, 1, 30))),
    ('sine fold', stair(lambda u: fold_sine(u, 0.9, 4))), ('triangle fold', stair(lambda u: fold_tri(u, 0.9, 4))),
    ('random spectra 1', stair(S2(41, 42, 1.0))), ('random spectra 2', stair(S2(43, 44, 1.2, 0.4))),
    ('saw to pulse', stair(saw_pulse)), ('saw to triangle', stair(saw_tri))])

BANKS['ppg_2'] = ('PPG B: stair-stepped vocal, FM and additive textures', [
    ('vowels a-e-i', stair(V('aei', 130))), ('vowels o-u-a', stair(V('oua', 130))),
    ('vowels (female)', stair(V('eioau', 230, 6))), ('choir', stair(V('uoa', 170, 3))),
    ('FM 1:1', stair(lambda u: fm(u, 1, 5))), ('FM 1:2', stair(lambda u: fm(u, 2, 5))), ('FM 1:3', stair(lambda u: fm(u, 3, 4))),
    ('ring modulation', stair(lambda u: ring(u, 1, 6))),
    ('organ', stair(lambda u: drawbars(u, [1, .6, .2, 0, 0, 0, 0, 0, 0], [.5, 1, .9, .7, .6, .5, .3, .4, .2]))),
    ('bells', stair(lambda u: partials(u, [1, 2, 3, 5, 7, 9], [1, .2, .5, .2, .1, .05], [.8, .7, .3, .6, .5, .4], 0.01))),
    ('glass', stair(lambda u: glass(u, 3, 12))), ('tines', stair(lambda u: partials(u, [1, 2, 3, 4, 5], [1, .4, .2, .1, .05], [1, .9, .6, .4, .3]))),
    ('random spectra 3', stair(S2(45, 46, 1.4))), ('random spectra 4 (bright)', stair(S2(47, 48, 0.6))),
    ('strings-ish', stair(lambda u: from_amps(reso(saw, 2 + 9 * u, 1.8)))), ('coarse stairs (32 steps)', stair(lambda u: harm_count(u, 3, 30), hold=8, bits=6))])

BANKS['provs_1'] = ('VS A: glassy additive and evolving spectra', [
    ('glass A', lambda u: glass(u, 2, 12, 1.0)), ('glass B (wide)', lambda u: glass(u, 4, 20, 2.5)),
    ('two-partial sweep', lambda u: from_amps(peak(1, 0.5) + peak(geo(2, 24, u), 0.7))),
    ('three-partial sweep', lambda u: from_amps(peak(1, 0.5) + 0.7 * peak(geo(2, 12, u), 0.6) + 0.5 * peak(geo(3, 30, u), 0.6))),
    ('soft pad 1', S2(51, 52, 2.2)), ('soft pad 2', S2(53, 54, 1.9, 0.3)), ('soft pad 3', S2(55, 56, 2.5)),
    ('strings', lambda u: from_amps(reso(saw, 2 + 10 * u, 2.0))), ('brass-like', lambda u: from_amps(lowp(saw, geo(3, 30, u), 2) * (1 + 2 * peak(4 + 6 * u, 2)))),
    ('reed', lambda u: from_amps(reso(odd, 3 + 10 * u, 4))),
    ('bright additive', S2(57, 58, 0.7)), ('hollow pulse', lambda u: pwm(u, 0.5, 0.2)),
    ('odd / even', oddeven), ('harmonic comb', lambda u: comb(u, 1, 5)),
    ('sine to saw', lambda u: harm_count(u, 1, 36)), ('sine to triangle-fold', lambda u: fold_sine(u, 0.9, 3))])

BANKS['provs_2'] = ('VS B: metallic, FM and digital textures', [
    ('FM 1:1', lambda u: fm(u, 1, 8)), ('FM 1:2', lambda u: fm(u, 2, 8)), ('FM 1:3', lambda u: fm(u, 3, 7)),
    ('FM 1:5', lambda u: fm(u, 5, 6)), ('FM 1:6', lambda u: fm(u, 6, 6)), ('FM 1:8', lambda u: fm(u, 8, 5)),
    ('bell', lambda u: partials(u, [1, 2, 3, 5, 6, 8, 10], [1, .3, .5, .2, .2, .1, .05], [.6, .8, .4, .6, .5, .4, .4], 0.012)),
    ('metal bar', lambda u: partials(u, [1, 3, 6, 10, 15], [1, .5, .3, .2, .1], [.5, 1, .7, .6, .5])),
    ('ring', lambda u: ring(u, 1, 7)), ('random metallic', S2(61, 62, 0.9, 0.6)),
    ('random digital', S2(63, 64, 0.6, 0.3)), ('comb (odd)', lambda u: comb(u, 1, 7, odd)),
    ('sync (saw)', lambda u: sync_wave(u, 1, 10)), ('sync (sine)', lambda u: sync_wave(u, 1, 12, 'sine')),
    ('fold (sine)', lambda u: fold_sine(u, 1, 8)), ('fold (triangle)', lambda u: fold_tri(u, 1, 8))])

# ---------------------------------------------------------------- output
def render(recipes):
    waves = []
    for name, f in recipes:
        for j in range(8):
            w = norm(f(j / 7.0))
            waves.append(np.append(w, w[0]))
    return np.concatenate(waves)

def write(path, data):
    pcm = np.round(np.clip(data, -1, 1) * 32767).astype('<i2')
    with wave.open(path, 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(48000); f.writeframes(pcm.tobytes())

if __name__ == '__main__':
    out = sys.argv[1]
    docs = sys.argv[sys.argv.index('--docs') + 1] if '--docs' in sys.argv else None
    lines = ['# Generated wavetable banks', '',
             'Original, procedurally generated waves *in the style of* the instruments named; not dumps or',
             'copies of any instrument\'s data. Each bank = 16 tables of 8 waves (`tools/style_gen.py`).', '']
    for fname, (title, recipes) in BANKS.items():
        data = render(recipes)
        assert np.isfinite(data).all() and len(data) == 128 * 257
        write(os.path.join(out, fname + '.wav'), data)
        print(fname, len(data) // 257, 'waves')
        lines += ['## %s (`%s.wav`)' % (title, fname), '', '| Table | Contents |', '|---|---|']
        lines += ['| %d | %s |' % (i + 1, n) for i, (n, _) in enumerate(recipes)] + ['']
    if docs:
        open(docs, 'w').write('\n'.join(lines))
