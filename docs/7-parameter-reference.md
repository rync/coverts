# 7. Parameter reference

Engine keys (sent with `engine.pset`). "UI" is the norns parameter id. Ranges are those set in
`coverts.lua`; the engine itself does not clamp most of them.

## Oscillators

| Engine key | UI id | Range | Meaning |
|---|---|---|---|
| `shape1/2` | `o1_src/o2_src` | 0–4 | saw, pulse, tri, sine, wavetable (UI source list also selects the bank) |
| `pos1/2` | `o1_pos/o2_pos` | 0–1 | wave position / pulse width |
| `range1/2` | `o1_range/o2_range` | −24…24 st | octave/semitone offset |
| `tune1/2` | `o1_tune/o2_tune` | −100…100 ct | fine tune |
| `buf1/2`, `nw1/2`, `off1/2` | `o1_tab/o2_tab` (via `osc_bank`) | ALL, 1–8 | buffer number, wave count and first wave of the selected table |
| `drift` | `drift` | 0–1 | analog drift depth |

## Mixer

| Key | UI id | Range | Meaning |
|---|---|---|---|
| `balance` | `balance` | 0–1 | osc 1 ↔ osc 2 |
| `xmode` | `xmode` | 0–4 | mix, sync, ring, fold, crush |
| `xamt` | `xamt` | 0–1 | x-mod amount |
| `sublevel`, `subshape` | `sub_level`, `sub_shape` | 0–1, 0–3 | sub |
| `noise` | `noise` | 0–1 | noise level |
| `drive` | `drive` | 0–1 | pre-filter saturation |

## Filter

| Key | UI id | Range | Meaning |
|---|---|---|---|
| (`ftype` command) | `ftype` | 0–6 | model, new notes only |
| `cutoff` | `cutoff` | 20–16000 Hz | base cutoff (exp) |
| `res` | `res` | 0–1 | resonance |
| `fmode` | `fmode` | 0–1 | model-specific "shape" |
| `fextra` | `fextra` | 0–1 | model-specific "extra" |
| `fpar` | `fpar` | 0/1 | DUALSVF routing |
| `ktrack` | `ktrack` | 0–1 | key tracking, octaves/octave |
| `fenv` | `fenv` | −1…1 | ENV1 → cutoff, ±6 oct |

## Envelopes (n = 1…3)

`a{n}`, `d{n}`, `r{n}` 0.001–10 s (release to 12 s); `s{n}` 0–1; `cv{n}` −8…8.

## LFOs

| Key | Range | Meaning |
|---|---|---|
| `l{1-3}shape`, `l4shape` | 0–6 | shape |
| `l{n}rate` | 0.01–50 Hz | rate |
| `l{1-3}slew` | 0–1 | smoothing (×0.25 s) |
| `l{1-3}scope` | 0/1 | shared / per voice |
| `l{n}sync` | 0/1 | free / key phase (per-voice LFOs only) |
| `l4delay` | 0–5 s | delay before LFO4 starts |
| `l4fade` | 0–8 s | fade-in time |

## Modulation

| Key | Meaning |
|---|---|
| `d{1-21}s{1-3}` | source index of input *j* on destination *d* (compiled by Lua) |
| `d{1-21}a{1-3}` | amount of that input |
| `x{1-4}a`, `x{1-4}b` | modifier inputs (0–14) |
| `x{1-4}op` | 0 ×, 1 avg, 2 min, 3 max, 4 lag, 5 s&h |
| `x{1-4}p` | modifier amount / lag time (0–1) |

## Voice

| Key | UI id | Meaning |
|---|---|---|
| `amp` | `level` | level × 0.9 |
| `pan`, `spread` | `spread` | static pan; random per-voice pan spread |
| `glide` | `glide` | 0–5 s |
| `bendrange` | `bendrange` | 0–24 st |
| `velamt` | `velamt` | velocity → level (0 = none, 1 = full) |
| `poly` (command) | `poly` | 1–12 voices |

The matrix slot params (`m1src` … `m14amt`) and modifier params exist only on the Lua side.
