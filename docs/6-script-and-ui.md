# 6. Script and UI

## coverts.lua

* **MIDI** (`midi_event`): note on/off (velocity 0 = off), pitch bend → `engine.bend`, channel
  pressure → `engine.pressure`, CC1 → `engine.modwheel`, CC64 → `engine.sustain`, CC120/123 →
  `engine.all_off`. Channel is filtered by the `midi_channel` param (0 = omni).
* **Parameters** are declared with three small helpers: `opt` (option list), `ctl` (control, 400
  steps across the range via quantum 0.0025), `num` (integer). Each registers a default in
  `UI.defaults`, used by K2-reset and *init patch*. Most actions are one-line `engine.pset` calls.
* **Source parameter** merges shape + bank (see [3](3-oscillators-and-wavetables.md)).
* **`ftype`** sends `engine.ftype(i−1)`; it takes effect on the next note.
* **Level** is `engine.pset("amp", v·0.4)`.
* **Randomize** sets the wavetable oscillators, positions, filter, envelope and LFO values, and
  fills four matrix slots with random source/destination pairs; the rest are cleared.
* `params:bang()` at the end of `init` pushes every parameter to the engine once.
* A `metro` redraws the screen at 15 fps.

## lib/ui.lua

The screen is a header, a graph area and a 4×2 grid of cells (`PAGES` table).

| Page | Graph |
|---|---|
| OSC 1, OSC 2 | both oscillator waveforms (wavetable cycles at the selected table and POS); cells: SOURCE, TABLE, POS, RANGE, TUNE |
| MIX > FILTER | the combined oscillator-section output, **static** preview before the filter |
| FILTER | analytic filter response (see [4](4-filters.md)), cutoff marker |
| ENV 1–3 | curved ADSR with the same `curve` formula as `Env.adsr` |
| LFO 1–4 | one cycle of the shape; LFO4 also shows delay and fade-in |
| MOD MATRIX | 14 rows × source/destination/amount, scrolling |
| MOD OPS | 4 rows × A / function / B / amount |
| VOICE | one dot per voice slot (filled = a key is held; keys held, not releasing tails) and the held note names |

Header dots show page position. All text uses the norns default pixel font at size 8, with brighter label levels; page captions that used a tiny size-6 font were removed (the page name is in the header).

**Initialization.** A fresh script and *init patch* give a plain starting point: both oscillators saw, position 0, range 0, tune 0, balance 0.5, x-mod 0, sub/noise/drive 0, filter fully open (16 kHz) with resonance, extra, key tracking and envelope amount all 0, amp envelope sustaining at full level, drift/spread/velocity/glide 0, and an **empty modulation matrix**. K2 resets a cell to the same defaults.

**Input.** E1 page, E2 cursor, E3 value. Continuous parameters accelerate: turn faster than
120/60/30 ms between ticks → ×2/×4/×8. Option and integer parameters step one at a time.
K2 resets the selected cell to its default; K3 plays C3 (note 48) while held.

### Why previews are static

The oscillator-mix preview is computed in Lua from the parameter values (using the same wavetable
files, loaded by `lib/waves.lua`); it does not tap the real audio. This costs essentially no
audio CPU, at the price of not showing modulation in motion.

### Reading the wavetable files from Lua

`waves.lua` opens each `.wav`, skips a 44-byte header, reads 16-bit samples, and exposes
`sample(bank, pos, phase)` with the same crossfade as the engine. Files are cached after first read.

## Extending the UI

Page cells are 4 across; a page can have up to 8 cells. Add a `{ id, label }` entry to the page's `cells` (label may be a function returning `nil` to
grey the cell out, as the filter page does with `FL`).
