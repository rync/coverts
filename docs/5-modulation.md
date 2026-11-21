# 5. Modulation

Modeled on the Ambika's layout – three envelopes, four LFOs, a matrix, and modifier "operators" –
but with continuous (float) values throughout instead of 7-bit steps.

## Envelopes

Three ADSRs per voice, all triggered by the same gate:

| Env | Default role | Output goes to |
|---|---|---|
| ENV1 | filter | cutoff directly via `fenv` (−1…1, up to ±6 octaves) and as a matrix source |
| ENV2 | amplifier | VCA directly; also decides when the voice ends (`doneAction 2`) |
| ENV3 | aux | matrix source only |

Each has attack, decay, sustain, release and a **curve** (`cv`, −8…+8, the `curve` argument of
SuperCollider's `Env.adsr`): negative = fast start, snappy / exponential; 0 = linear; positive =
slow start. Times are 1 ms…10 s (release 12 s) with an exponential encoder mapping. Attack, decay
and release are floored at 1 ms inside the engine.

## LFOs

Seven shapes (`lfoFn`): 0 triangle, 1 saw up, 2 square, 3 sample & hold (`LFNoise0`), 4 smooth
random (`LFNoise1`), 5 sine, 6 saw down. All are bipolar (−1…1) at 0.01–50 Hz.

| LFO | Where it runs | Extras |
|---|---|---|
| 1, 2, 3 | **shared** (one LFO in `\coverts_lfo`, written to bus 3–5) **or per voice**, selected by `l{n}scope` | `slew` smooths the output (`Lag`, time = `slew·0.25` s); per-voice copies also have `sync`: *key* = every voice starts at phase 0, *free* = random start phase per voice |
| 4 | always per voice | `delay` then `fade` in (an `Env([0,0,1],[delay,fade])` multiplies the LFO), `sync` as above |

Shared means every sounding voice sees the identical signal, so phase-locked movement across a
chord; voice means each note has its own, giving the "analog ensemble" spread. The scope switch
is a `Select.kr` between the bus value and a private LFO inside the voice. (The private LFOs
exist in every voice and cost CPU even in shared mode, because both branches of a `Select.kr`
are always evaluated.) Rate changes are lagged 50 ms.

## Sources

`base` (15 values) is evaluated once per voice; the numbers are the index used by the matrix.

| Index | Source | Range |
|---|---|---|
| 0 | off | 0 |
| 1–3 | ENV1–3 | 0…1 |
| 4–6 | LFO1–3 | −1…1 |
| 7 | LFO4 | −1…1 (× fade-in) |
| 8 | VEL | 0…1 |
| 9 | MWHEEL | 0…1 (global) |
| 10 | PRESS | 0…1 (global) |
| 11 | KEY | `(note−60)/60`, about −1…1 across the keyboard |
| 12 | RAND | random −1…1, chosen once per note |
| 13 | BEND | −1…1 (global) |
| 14 | CONST | 1 |
| 15–18 | OP1–4 | modifiers, below |

## Modifiers (OP1–4)

Each takes two base sources (A, B – not other OPs, so no feedback) and a function:

| `op` | Function | `p` ("amount / time") |
|---|---|---|
| 0 × | `A·B` | – |
| 1 + | `(A+B)/2` | – |
| 2 min | `min(A,B)` | – |
| 3 max | `max(A,B)` | – |
| 4 lag | `Lag(A, 3·p)` – B ignored | smoothing time up to 3 s |
| 5 s&h | `Latch(A, B > 0.5)` | – |

Setting B to CONST makes "A × 1" – a handy way to pass a source through. Because "off" is 0,
`×` with an unset input yields 0.

## Destinations

| Index | Destination | Effect of a modulation value *m* |
|---|---|---|
| 1 | POS1 | wave position / pulse width of osc 1, +m (clipped 0…1) |
| 2 | POS2 | same, osc 2 |
| 3 | POS1+2 | both |
| 4–6 | PITCH1 / PITCH2 / PITCH12 | +12·m semitones |
| 7 | BAL | +0.5·m on balance |
| 8 | CUTOFF | +5·m octaves |
| 9 | RESO | +0.5·m |
| 10 | SUB | +0.5·m |
| 11 | NOISE | +0.5·m |
| 12 | LEVEL | gain × (1 + m), floored at 0 – so −1 closes the VCA, +1 doubles it |
| 13 | XAMT | +0.5·m |
| 14 | PAN | +m (also gets a random per-voice offset of `spread`) |
| 15 | DRIVE | +0.5·m |
| 16 | FSHAPE | +0.5·m on the filter's MODE |
| 17 | FEXTRA | +0.5·m on the filter's EXTRA |
| 18-21 | L1..L4 RATE | rate × 2^(4·m) |

## The matrix and how it's compiled

The user sees **14 slots**: `source → destination × amount(−1…1)`. The engine does not evaluate
slots; it evaluates **21 destinations × 3 inputs**:

```
dm[d] = Σ_{j=1..3}  Select.kr(d{d}s{j}, srcs) · Lag(d{d}a{j}, 0.03)
```

`sync_matrix()` in `coverts.lua` rebuilds this on any slot change: it walks the 14 slots, drops
the off ones, and assigns each remaining slot to the next free input (1–3) of its destination.
Only values that actually changed are sent (the `sent` cache), so sweeping an amount costs one
OSC message per move.

Consequences, deliberately chosen:

* **At most 3 slots per destination.** Later ones are silently ignored. The rationale is
  constant CPU: 21×3 `Select.kr`s regardless of how many slots are used.
* Slot order matters only when a destination has more than 3 slots.
* The matrix starts **empty**. (Earlier versions pre-filled LFO1→POS1+2, MWHEEL→CUTOFF and PRESS→CUTOFF.)

All matrix processing is control-rate; fast modulation (audio-rate FM etc.) is not available.

## Additions in Coverts

* LFO shapes 8-19 are read from a 257-frame table built in `makeLfoTable` (trapez, rnd sqr, exp up, exp dn, bounce, dbl sin, heart, pulse25, step 4, step 8, step A, step B). They are this project's own designs, not copies of the Ambika list.
* `l{n}delay` / `l{n}fade` (all four LFOs): the LFO output is multiplied by `Env([0,0,1],[delay,fade])` at note start.
* Destinations 18-21 (`L1..L4 RATE`): rate x 2^(4 x mod). Inputs are read from the previous control block (LocalIn/LocalOut), so LFOs can modulate each other without a loop; OP1-4 are not available as sources there.
