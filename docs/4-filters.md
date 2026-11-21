# 4. Filters

Seven models, selected with the FILTER page's MODEL (`ftype`). Each is a function
`{ sig, cut, res, mode, extra, par }` → signal, compiled into its own SynthDef. All are
**character emulations built from SuperCollider building blocks** (MoogFF, BLowPass/BHiPass/BPF, tanh,
rounding), not circuit-level models.

**High-cutoff fix.** The first version used SuperCollider's `RLPF`/`RHPF`. Their coefficient
mapping runs out of range at high cutoffs: above roughly 6 kHz the response sags well below the
set cutoff, resonance shrinks, and with large `rq` (PRO VS's first stage uses 1.85) it can
collapse entirely, which was heard as squelching on high notes. All low-/high-pass stages now use the RBJ-biquad
`BLowPass`/`BHiPass`, which match `RLPF` at low cutoffs and stay correct up to the 16 kHz
ceiling.

## Common inputs

| Input | Meaning |
|---|---|
| `cut` | cutoff in Hz, after modulation: `cutoff · 2^cutOct`, clipped 20…16000 |
| `res` | 0…1 (+ RESO modulation × 0.5, clipped) |
| `mode`, `extra` | the two generic controls, relabelled per model on the FILTER page (+ FSHAPE/FEXTRA modulation × 0.5) |
| `par` | 0/1, used by DUALSVF only (series / parallel) |

```
cutOct = CUTOFFmod·5 + env1·fenv·6 + ((note−60)/12)·ktrack
```

So the matrix moves the cutoff up to ±5 octaves per unit, ENV1 up to ±6 octaves at full
`fenv` (it may be negative), and key tracking follows pitch at `ktrack` octaves per octave.
After the filter a `LeakDC` removes any offset.

## The models

| # | Name | `mode` | `extra` | `par` | Character |
|---|---|---|---|---|---|
| 0 | **SMR4** | – | – | – | `MoogFF` 4-pole ladder, resonance 0…3.9, output boosted by `1 + 0.8·res` to offset the ladder's passband loss |
| 1 | **MISSION** | LP → BP → HP | – | – | Two cascaded 2-pole stages with pole mixing; stage 1 fixed rq 0.9, stage 2 gets the resonance (`rq = 1−0.92·res`, min 0.06). |
| 2 | **DUALSVF** | LP → BP → HP (both) | SPREAD: second cutoff = `cut·2^(4·extra−2)` (−2…+2 oct) | series / parallel | Two 2-pole morphing filters. Parallel sums them ×0.6. |
| 3 | **POLIVOK** | LP ↔ BP | DIST: post-gain `1+6·extra` into `tanh` | – | Input `tanh(1.5x)`, 2-pole, harsh output saturation |
| 4 | **MS-20** | – | HPF: highpass at `0.9·extra·cut` before the LPF | – | HPF into saturating LPF, output `tanh(y(1+res))` |
| 5 | **DIGITAL** | LP ↔ HP | CRUSH: `steps = 2^(12−9·extra)` | – | Filter then quantise the output |
| 6 | **PRO VS** | 4-pole ↔ 2-pole | BASS | – | Clean OTA-style low-pass, see below |

Notes on fidelity:

* MISSION is called a "4-pole mission" because the two stages combine to 24 dB/oct in LP/HP; the
  BP position is a band-pass of band-pass, steeper than a 2-pole BP.
* In DUALSVF the BP outputs are scaled ×1.6 and in POLIVOK ×2 to keep levels comparable between
  LP and BP.
* Resonance is mapped per model to the filter's Q/rq so that 1.0 is "near self-oscillation" but
  stable; none of the models are intended to self-oscillate into a pure sine.

## PRO VS (Prophet VS style)

The Prophet VS is a four-pole low-pass built around Curtis CEM filter chips (Doepfer's
documentation names the CEM 3372/3378 family for the VS; sources differ on exact chip numbers,
so this is stated loosely). The emulation aims at its clean, even sound, not at its circuit.

```
x   = tanh(0.9·sig)                          gentle input saturation (OTA-like)
s1  = RLPF(x, cut, 1.85)                     first 2-pole stage, nearly flat (Butterworth-ish)
s2  = RLPF(tanh(1.1·s1), cut, rq4)           second stage takes the resonance, rq4 = max(0.04, 0.77 − 0.73·res)
p2  = RLPF(x, cut, rq2)                      alternative 2-pole path, rq2 = max(0.04, 1 − 0.96·res)
y   = XFade2(s2, p2, mode·2−1)               MODE: 0 = 4-pole, 1 = 2-pole, continuous in between
bass = LPF(x, 140)·res·extra·0.9             BASS: low-end make-up that returns as resonance rises
out = tanh(0.9·(y + bass))
```

Controls on the FILTER page: **POLES** (MODE) slides from 24 dB/oct to 12 dB/oct; **BASS**
(EXTRA) restores the bass that a resonant ladder normally loses. Unlike SMR4 the resonance peak
is kept fairly clean and the cascade between the stages is lightly saturated rather than
overdriven.

## The filter plot

`filter_mag` in `lib/ui.lua` draws an *analytic approximation* of each model: the textbook
magnitude of two- and four-pole low-pass/high-pass sections with the same Q mapping as the engine,
plus a mild fudge for the ladder's resonance and for PRO VS's bass term. It does not include the
saturation stages, so the drawn curve and the real sound agree on cutoff, slope and peak
height but not on harmonic content.
