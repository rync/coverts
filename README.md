# coverts — a polyphonic Shruthi-1 / Ambika-inspired synth for norns

A norns port/re-imagining of the Mutable Instruments Shruthi-1: two oscillators,
sub, noise, x-mod, a selectable filter "board", two ADSRs, two LFOs and a modulation
matrix — now polyphonic (1–12 voices), with the Sheep and Plaits wavetables.

**Documentation:** a detailed wiki on how the engine works is in [`docs/`](docs/README.md).

## Install
Copy this folder to `~/dust/code/coverts` (keep the folder name), then **restart norns**
once so SuperCollider compiles the engine. Needs a MIDI keyboard (K3 auditions a note).

## Controls
E1 page · E2 cell · E3 value · K2 reset cell · K3 hold = play C3.
Pages: **OSC 1, OSC 2, MIX, FILTER, ENV 1-3, LFO 1-4, MOD MATRIX, MOD OPS, VOICE** (14; dots in the header show position). Every page draws a live graph (wavetables, the oscillator section feeding the filter,
filter response, curved envelopes, LFO shapes incl. LFO4's delay/fade-in, voice activity).
MIDI: notes, velocity, pitch bend, mod wheel (CC1), channel pressure, sustain (CC64).
Params menu: all parameters, MIDI device/channel, "randomize patch", "init patch", PSETs.
The initial patch is deliberately plain (saw, position/detune 0, filter open, empty matrix) so you can build sounds from scratch. All voices pass a master limiter, so chords don't clip the output.

## Oscillators
Per oscillator: saw, pulse (POS = width), triangle, sine, or one of six wavetable banks.
TABLE picks ALL (the whole bank) or one of N tables of 8 waves (N = 6 to 16 depending on the bank) (like a Plaits bank); POS then scrubs through that window with smooth, audio-rate crossfading between neighbouring waves.
| Bank | Source | Waves |
|---|---|---|
| SHEEP1, SHEEP2 | Sheep (Tides firmware) banks 1–2 | 64 each |
| SHEEP3 | Sheep bank 3 = the Shruthi/Ambika wavetable set | 50 |
| PLAIT1–3 | Plaits wavetable banks A–C | 64 each |
X-mod: mix, sync (saw/tri/sine/wavetable on osc 2), ring, fold, crush.

## Filter models (FLT page; applies to notes played after you change it)
1. **SMR4** – 4-pole resonant ladder (MoogFF).
2. **MISSION** – 4-pole that morphs LP → BP → HP (SHAPE).
3. **DUALSVF** – two 2-pole morphing filters, series/parallel, SPREAD offsets the second.
4. **POLIVOK** – 2-pole LP/BP with hard distortion (DIST).
5. **MS-20** – HPF into a saturating 2-pole LPF (HPF amount).
6. **DIGITAL** – crunchy LP/HP with bit reduction (CRUSH).
7. **PRO VS** – clean, OTA-style 24 dB low-pass in the spirit of the Prophet VS; POLES slides 4-pole → 2-pole, BASS keeps the low end as resonance rises.
These are character emulations built from SuperCollider biquads/ladder plus saturation,
not circuit-level models.

## Modulation (Ambika-style)
- **3 ADSR envelopes** – ENV1 filter, ENV2 amp, ENV3 aux (matrix source only). Each has a
  continuous CURVE (-8…+8) from snappy/exponential to slow-start.
- **4 LFOs** – LFO1–3 are patch-level by default (one LFO shared by all voices, like the
  Ambika's) and each has a SCOPE switch: *shared*, or *voice* (every voice gets its own copy,
  with PHASE free-running or key-synced). LFO4 is always per voice with DELAY, FADE-IN and
  free/key phase. Shapes: tri, saw, square, s&h, random, sine,
  saw down. LFO1–3 have a SMOOTH control (slews steps and edges).
- **14-slot matrix** (MOD page) – source → destination × amount (-1…+1).
  Sources: ENV1-3, LFO1-4, VEL, MWHEEL, PRESS, KEY, RAND, BEND, CONST, OP1-4.
  Destinations: POS1, POS2, POS1+2, PITCH1/2/12, BAL, CUTOFF, RESO, SUB, NOISE, LEVEL, XAMT,
  PAN, DRIVE, FSHAPE, FEXTRA. Pitch 1.0 = 12 semitones; cutoff 1.0 = 5 octaves.
  The engine handles up to **3 slots per destination**; further ones on the same destination
  are ignored (this keeps CPU flat).
- **4 modifiers** (OPS page) – combine two sources into OP1–4: multiply, average, min, max,
  lag (A smoothed; amount = time) or sample & hold (A sampled when B > 0.5).
- **Smooth everywhere** – all continuous parameters are floats, smoothed in the engine (no
  zipper noise), encoders have 400 steps across their range plus acceleration on fast turns.
  Matrix amounts are smoothed too.

## Wavetables
`waves/*.wav` are rendered by `tools/export_waves.py` from the Plaits and Tides/Sheep
wavetable generators in github.com/pichenettes/eurorack (MIT, see LICENSE-wavetables.txt).
Plaits' algorithmic tables are re-rendered at 256 samples/wave; Braids-derived ones are
FFT-resampled from 128. Playback is plain (not band-limited), so high notes alias a bit,
as on the original.

## Verification status
Checked here: engine compiles in SuperCollider 3.13, all seven SynthDefs build and render
clean audio offline (no NaN/DC), Lua runs under a mock norns (all pages, MIDI, randomize).
**Not run on real norns hardware.** High-cutoff filter response, chord headroom and wavetable-position smoothness were each checked in offline renders. The expanded modulation was render-tested too (all seven filters with matrix, modifier, ENV3 and
LFO4 active). Rough load: ~5% of one desktop core per 8 voices (unchanged by the new modulation);
expect several times that on a Pi 3B+/CM3 — lower POLYPHONY if you hear dropouts.

## Coverts: what's new in this version

* **Name**: Coverts, after the covert feathers that make up a peacock's "tail". Install in `~/dust/code/coverts`. PSETs saved under the old script name do not carry over.
* **Polyphony / gain**: all parameters now live in one patch synth that smooths them once and shares them with every voice over a control bus (less per-note work, small `s_new` messages). The master stage scales by 1/sqrt(voices) and then limits; the VOICE page shows limiter gain reduction (`LIM`, dB) and voice steals (`STL`).
* **Sources**: OFF, saw, pulse, tri, sine, then 14 wavetable banks. `TABLE` is only active (and only reachable with E2) for wavetable sources, `POS` only for pulse and wavetables; inactive cells are dimmed and skipped. In the params menu they are hidden.
* **TABLE** goes `ALL`, `1/N` ... `N/N` where N is the bank's real table count (SHEEP3: 6; the 128-wave banks: 16). The number can never exceed the bank.
* **Banks**: the eight `~` banks (AMB A/B, BLO A/B, PPG A/B, VS A/B; 128 waves = 16 tables each) are **generated in the style of** Ambika, Blofeld, PPG Wave and Prophet VS by `tools/style_gen.py`. They are not copies of any instrument's data. Contents: `docs/wavetable-tables.md`.
* **LFOs**: 19 shapes, DELAY and FADE-IN on all four, and four new matrix destinations `L1..L4 RATE` (exponential, +-4 octaves at full amount). An LFO whose rate is modulated runs per voice.
