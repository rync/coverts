# 3. Oscillators and wavetables

## Pitch

For each oscillator the frequency in Hz is

```
f = midicps( n0 + range + tune·0.01 + (pitchMod1or2 + pitchMod12)·12 + drift )   clipped to 8…18000 Hz
```

* `n0` is the glided, bent note (see [2](2-voices-and-commands.md)).
* `range` is in semitones (−24…24 in the script), `tune` in cents.
* The matrix destinations PITCH1 / PITCH2 / PITCH12 add `amount × 12` semitones, i.e. modulation
  value 1.0 = one octave.
* **Drift**: `LFNoise1` (0.37 Hz on osc 1, 0.41 Hz on osc 2) × `drift` × 0.15 semitone. Different
  rates keep the two oscillators from drifting in lock-step. Osc 2 defaults to +6 cents.

## Shapes

`shape` selects one of: 0 saw, 1 pulse, 2 triangle, 3 sine, 4 wavetable.

| Shape | Implementation | POS does |
|---|---|---|
| saw | `Saw.ar` (band-limited) | nothing |
| pulse | `Pulse.ar`, width = POS clipped 0.04…0.96 | pulse width |
| triangle | computed from a `Phasor` (not band-limited) | nothing |
| sine | `SinOsc` driven by the phasor | nothing |
| wavetable | see below | scans waves in the bank |

On the Lua side the "source" parameter merges shape and bank: choices 1–4 are saw/pulse/tri/sine,
5–10 are SHEEP1–3 and PLAIT1–3 (which set `shape = 4` and call `osc_bank`).

## Wavetable reader

A **bank** is one `.wav` file (50 to 128 waves). A **table** is a window of 8 consecutive waves inside it, like the 8 tables of 8 waves in a Plaits bank. The TABLE parameter picks `ALL` (the whole bank) or table 1–8, and POS then sweeps only that window. A bank that is not a multiple of 8 gives its last table the remainder (SHEEP3, 50 waves: tables 1–5 have 8 waves, table 6 has 10; tables 7 and 8 select table 6). The window is an offset and count into the same buffer (`off`, `nw` in the voice), so there are no extra files.

Each `.wav` is 16-bit mono, **257 frames per wave** (256 samples plus one repeated wrap point so
interpolation at the end of a cycle is clean). Waves lie one after another in the buffer.

For wave position `pos` (0…1) in a bank of `nw` waves:

```
wp = pos·(nw−1);   w0 = floor(wp);   frac = wp − w0;   w1 = min(w0+1, nw−1)
read(w) at index (off + w)·257 + phase·256   (BufRd, interpolation mode 2 = linear)
out = read(w0)·(1−frac) + read(w1)·frac
```

The position is a crossfade between adjacent waves. The position signal (knob + matrix) is
converted to **audio rate** and smoothed with a 4 ms lag before it reaches the reader. Earlier
versions used the 750 Hz control-rate value directly, which made fast position modulation
step audibly (zipper noise); measured offline, block-rate steps in the output went from
1.9× to 1.0× (no steps). Pulse width uses the same smoothed signal.

Bank sizes: SHEEP1 64, SHEEP2 64, SHEEP3 50, PLAIT1–3 64. The buffers are loaded once, from
`../waves/` relative to the engine file (`PathName(Engine_Coverts.filenameSymbol).pathOnly`).

**Aliasing:** playback is plain table lookup, not band-limited or mip-mapped. High notes on bright
waves alias. The original hardware has the same character, and it saves CPU.

### Where the tables come from

`tools/export_waves.py` renders them from the Plaits and Tides/Sheep wavetable generators
(`plaits_gen.py`, `sheep_gen.py`). Plaits' algorithmic tables are re-rendered at 256 samples per
wave; Braids-derived waves are FFT-resampled from 128. SHEEP3 is the 50-wave set that the Shruthi
and Ambika use. See `LICENSE-wavetables.txt`.

## Oscillator phases and sync

Two `Phasor`s run in parallel with the oscillators that need an explicit phase (triangle, sine,
wavetable): `ph1` free-runs at `f1`; `ph2` runs at `f2` and is **reset when `ph1` wraps** if
x-mod is *sync* (`syncTrig = (HPZ1(ph1) < 0) × issync`). For osc 2's saw, sync uses `SyncSaw.ar(f1, f2)`.
Pulse on osc 2 is *not* hard-synced (the library oscillator has no reset input), so SYNC audibly
affects saw / triangle / sine / wavetable on osc 2 only.

## Oscillator mix and x-mod

```
bal = balance + modBAL·0.5   (0 = osc 1 only, 1 = osc 2 only)
o12 = XFade2(o1, o2, bal·2−1)
```

`xmode` selects what the mixer sends on:

| xmode | Result |
|---|---|
| 0 mix | `o12` |
| 1 sync | `o12` (the sync happens inside osc 2, above) |
| 2 ring | crossfade from `o12` to `o1·o2·1.4` with `xamt` |
| 3 fold | `(o12·(1+6·xamt)).fold2(1)` – wavefolder |
| 4 crush | bit and sample-rate reduction: `steps = 2^(11 − 8·xamt)`, sample-and-hold at `SampleRate·(1−xamt)²` (floor 3 %) |

Modulation destination XAMT adds `amount × 0.5` to `xamt`.

## Sub oscillator and noise

`subshape`: 0 square −1 oct, 1 square −2 oct, 2 sine −1 oct, 3 sine −2 oct. The sub follows
**oscillator 1's modulated frequency** (including pitch modulation and drift), not the plain note.
Noise is `WhiteNoise.ar`.

```
sig = xm·0.7 + sub·sublevel·0.5 + noise·noiseLevel·0.5
```

SUB and NOISE levels accept modulation (`+ amount×0.5`, clipped 0…1).

## Drive

`sig = tanh(sig·(1 + 5·drive))·0.8`, with DRIVE modulatable. This stage sits **before** the
filter, so it changes how hard the filter is hit; each filter then applies its own saturation.

## Banks, tables and OFF (Coverts)

Source index 1 is OFF (shape 5, `DC.ar(0)`). A bank has `numFrames div 257` waves and `max(1, waves div 8)` tables; the last table takes the remainder. `lib/waves.lua` mirrors that rule (`W.ntabs`), and the TABLE parameter is clamped to it. The `~` banks are generated, see `tools/style_gen.py` and `wavetable-tables.md`.
