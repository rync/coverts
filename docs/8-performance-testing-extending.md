# 8. Performance, testing, extending

## Performance

* Measured offline on a desktop x86 core: roughly **5 % of one core per 8 voices**. The extra
  modulation (3 envelopes, 4 LFOs, matrix) did not change that appreciably, because the matrix
  is a fixed 21×3 `Select.kr` grid.
* A Pi 3B+/CM3 is several times slower. Lower `poly` if you hear dropouts. Defaults to 6 voices;
  the sampler-style 12-voice use case is the likely limit on that hardware and has *not* been
  measured on it.
* Cheapest levers: fewer voices; avoid DUALSVF in parallel (two extra filters); crush x-mod; the
  wavetable shape (two `BufRd` per oscillator).
* LFO1–3 private copies exist in every voice even when SCOPE is shared (see [5](5-modulation.md)).
* The master limiter is one `Limiter` on two channels (negligible).
* PRO VS runs four biquads (two in the 4-pole path, one in the 2-pole path, one bass LPF).

## How it was checked

Outside the package, on a desktop SuperCollider 3.13 build (no real audio device):

1. `sclang` compiles `Engine_Coverts.sc` against a stubbed crone class library and builds all
   SynthDefs.
2. Scores are rendered offline with `scsynth -N` and analysed in Python: NaN, peak, DC, spectra
   (e.g. confirming the shared / per-voice LFO difference and PRO VS stability at max resonance).
3. A Lua mock of norns (`texlua`) loads `coverts.lua`, steps through every page, MIDI messages,
   randomize/init and sweeps of the filter plot for all seven models.

Not covered: real hardware, real-time audio behaviour, MIDI devices, long-term voice leaks.

## Extending

### Add a filter
1. Append a function `{ sig, cut, res, mode, extra, par | ... }` to the `filters` array in
   `buildDefs` – it becomes `coverts_N` automatically and `ftype` clamps to the new size.
2. Add its name to the `ftype` options in `coverts.lua`.
3. Add a label row to `FL` in `lib/ui.lua` (use `nil` for unused controls) and, optionally, a
   branch in `filter_mag` for the plot (the branch index is the 1-based option number).

### Add a modulation source
Append to `base` in the voice (keep CONST at index 14 or renumber), add the name to `MOD_SRC` and
`MODX_SRC` in the same order. OP sources must stay after the base sources.

### Add a modulation destination
Increase `21` in the SynthDef (`dm`), `alloc` (`params` loop) and `NDEST` in Lua; add the name to
`MOD_DST`, then use `dsel.(n)` where it should act.

### Add a wavetable bank
Render a 257-frames-per-wave mono 16-bit WAV into `waves/`, add its name to `loadWaves` (and
`nwaves`; its 8-wave tables are derived automatically), to `W.files` / `W.names in `lib/waves.lua`, and to `SOURCES` in `coverts.lua`.
`setBank` clamps to the buffer count automatically.

### Known limitations
* Filter model switches are not instantaneous (new notes only).
* Bend, mod wheel and pressure are global, not per note.
* At most 3 matrix slots per destination.
* Pulse on osc 2 is not hard-synced.
* Wavetables are not band-limited.
* Modulation is control-rate.
