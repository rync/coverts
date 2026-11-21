# 2. Voices and commands

## Voice bookkeeping

`voices` is a `List` of events `(syn, note, held, sus)`:

* `syn` – the `Synth`
* `note` – MIDI note number
* `held` – key is physically down
* `sus` – key was released but the sustain pedal is holding it

### noteOn(n, v)

1. **Same-note retrigger.** Any existing voice on note `n` is killed first.
2. **Voice stealing.** While `voices.size >= maxVoices`, the victim is the first voice whose key
   is already up (`held == false`, i.e. one that is releasing or pedal-held), else the oldest voice.
3. A synth is created in `pg` with `out`, the control bus index, `note`, `lastnote` (for glide),
   `vel`, `gate = 1`, **plus a snapshot of every entry in the `params` dictionary**. This is
   how a new voice starts with the current knob positions.
4. The synth is registered with `NodeWatcher` and `onFree` removes it from `voices` when its
   amp envelope ends.

### Releasing

* `noteOff` → `releaseVoice` (gate 0, normal release) unless the sustain pedal is down, in which
  case the voice is only marked `sus`.
* `setSustain(0)` releases every voice marked `sus`.
* `killVoice` sets `gate = -1.02`, which makes the envelopes take a forced **20 ms** release
  (SuperCollider's negative-gate convention: the magnitude minus one is the release time in seconds).
  The node frees itself when envelope 2 finishes.
* `allOff` releases held voices and clears the pedal.

### Voice lifetime

Only **ENV2 (amp)** carries `doneAction: 2`. A voice therefore lives exactly as long as its amp
envelope, regardless of ENV1/ENV3 or LFOs. With sustain at 0 and a long decay the voice stays
until the decay finishes.

## Parameter updates

`setParam(key, val)`:

* if `key` is in `params`, store it **and `set` it on every live voice** – so knob changes apply
  to sounding notes immediately (except the filter model, see below);
* if `key` is in `lfoParams` (`l1…l3` shape/rate/slew), also set it on the shared LFO synth.

Because the snapshot of `params` is used for every new note, the engine stays consistent even if
the Lua side sends nothing at note time.

## Command API (what Lua can call as `engine.*`)

| Command | Args | Effect |
|---|---|---|
| `note_on` | `i f` note, velocity 0–1 | `noteOn` |
| `note_off` | `i` | `noteOff` |
| `sustain` | `i` (0/1) | sustain pedal |
| `all_off` | – | release all, clear pedal |
| `bend` | `f` −1…1 | writes bus 0; voices scale by `bendrange` semitones |
| `modwheel` | `f` 0–1 | bus 1 |
| `pressure` | `f` 0–1 | bus 2 |
| `pset` | `s f` key, value | generic parameter set (`setParam`) |
| `osc_bank` | `i i i` osc (1/2), bank (1–6), table (0 = whole bank, 1–8 = one 8-wave table) | choose the wavetable buffer, first wave and wave count for an oscillator |
| `ftype` | `i` 0–6 | filter model for *subsequent* notes |
| `poly` | `i` 1–12 | maximum voices (default 6 in the script) |

Bend, mod wheel and pressure are *global*: they go through one bus that every voice reads, so a
mod-wheel move affects all voices at once (there is no per-note expression).

## Glide

`n0 = Line.kr(lastnote, note, glide) + bend·bendrange`. Each new voice glides from the previously
played note, so glide is "legato-style by pitch history" rather than per-voice portamento on a
monophonic line. With `glide = 0` the line time is clamped to 1 ms.
