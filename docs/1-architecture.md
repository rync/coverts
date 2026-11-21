# 1. Architecture

## Three layers

```
 MIDI keyboard ─► coverts.lua ──── OSC (engine.* commands) ───►  Engine_Coverts.sc  ─► norns output
                   │  params, matrix compiler                      │ voices, LFO synth, buffers
                   └► lib/ui.lua (screen, encoders, graphs) ◄── reads params + waves/*.wav
```

* **`lib/Engine_Coverts.sc`** – a `CroneEngine`. Owns all sound: one SynthDef per filter model,
  a patch-level LFO synth, a control bus, six wavetable buffers, and the voice bookkeeping.
* **`coverts.lua`** – the norns script. Declares parameters, turns MIDI into engine commands,
  and compiles the modulation matrix into the form the engine wants.
* **`lib/ui.lua`** + **`lib/waves.lua`** – screen drawing. The UI never talks to the engine; it
  reads the Lua `params` and, for wavetable previews, reads the same `.wav` files from disk.

## What exists on the SuperCollider server

| Node / resource | Created | Purpose |
|---|---|---|
| `ParGroup` `pg` (tail of `context.xg`) | `alloc` | Holds all voices. A ParGroup lets scsynth spread voices across cores. |
| `\coverts_lfo` synth (head of `context.xg`) | `alloc` | LFO 1–3 shared by all voices; writes to the control bus. Runs before the voices each block. |
| Control bus, 6 channels | `alloc` | `0` pitch bend, `1` mod wheel, `2` channel pressure, `3–5` shared LFO 1–3 |
| 6 buffers | `loadWaves` | `sheep_1..3`, `plaits_1..3` wavetable banks |
| Voice bus (stereo audio) + `\coverts_master` synth (after the ParGroup) | `alloc` | All voices write to the private bus; the master applies a look-ahead limiter (ceiling 0.9, 5 ms) and writes to the norns output |
| One voice synth per sounding note | `noteOn` | Built from `coverts_0` … `coverts_6` according to the selected filter |

## SynthDefs

`buildDefs` defines a list of seven filter functions and a single `makeDef` that wraps each in
the *same* voice. This yields `coverts_0` … `coverts_6`. The filter model is chosen when a note
starts (`defNames[filterIdx]`), so **changing the filter only affects notes played afterwards**;
notes already sounding keep the filter they began with. The price of this design is that only
the selected filter's code ever runs (no CPU cost for unused models) – the cost is that the
change is not instant.

## Signal flow of one voice

```
   pitch ─► OSC1 ─┐
   (note,         ├─► balance ─► x-mod (mix/sync/ring/fold/crush) ─┐
    glide,        │                                                │
    bend, ───► OSC2 ┘                                              ├─► sum ─► drive (tanh)
    drift, mod)         sub oscillator (osc1 pitch, -1/-2 oct) ────┤        │
                        white noise ───────────────────────────────┘        ▼
                                                              FILTER (one of 7) ─► LeakDC
                                                                                      │
        ENV2 · velocity · level-mod · amp ─────────────────────────────────────► VCA ─► softclip ─► Pan2 ─► voice bus ─► master limiter ─► out
```

Modulation (envelopes, LFOs, matrix) feeds the pitch, wave position, balance, x-mod amount,
sub/noise level, drive, filter cutoff/resonance/shape/extra, level and pan. See
[5. Modulation](5-modulation.md).

## Control rate and smoothing

All continuous knobs go through `Lag.kr` (20–50 ms) before use, and the matrix amounts are
lagged 30 ms. Parameter changes arriving from norns therefore glide instead of stepping.
Discrete parameters (shapes, modes, source indices) are not smoothed.

## Gain staging, in order

1. Oscillator mix `× 0.7`; sub `× sublevel × 0.5`; noise `× level × 0.5`.
2. Drive: `tanh(sig × (1 + 5·drive)) × 0.8`.
3. Filter (each model has its own internal saturation, see [4. Filters](4-filters.md)).
4. `LeakDC`, then VCA, then `softclip` as a final safety net.
5. The Lua `level` parameter scales `amp` by `0.9` before sending (default level 0.6).
6. Master: all voices are summed on a private bus and pass a look-ahead `Limiter` (ceiling 0.9, 10 ms look-ahead (`dur` 0.01), after a 1/sqrt(voices) gain, so about 5 ms extra latency). Measured with the default patch, one voice peaks around 0.17, six voices around 0.68, and twelve around 0.8 before limiting; resonant or driven patches that go higher are caught by the limiter instead of clipping.

## Patch bus (Coverts)

`coverts_patch` holds every parameter as a NamedControl, smooths it once and writes it to a control bus. Voices and the LFO synth read it with `In.kr(parbus, nP)`. A note-on therefore sends only out, bus numbers, note, lastnote, velocity and gate; changing a parameter is one `patchSyn.set`, not one per voice.
