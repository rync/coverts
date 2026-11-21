# Coverts — engine wiki

How the engine works, page by page. Everything here is written against the code in
`lib/Engine_Coverts.sc`, `coverts.lua` and `lib/ui.lua`; where a number is quoted it is the
number in the code.

| Page | What it covers |
|---|---|
| [1. Architecture](1-architecture.md) | The three layers, one voice's signal flow, what runs where |
| [2. Voices and commands](2-voices-and-commands.md) | Note allocation, stealing, sustain, the engine's command API |
| [3. Oscillators and wavetables](3-oscillators-and-wavetables.md) | Oscillator shapes, wavetable reader, sync, x-mod, sub, noise, drive |
| [4. Filters](4-filters.md) | The seven filter models and their three generic controls |
| [5. Modulation](5-modulation.md) | Envelopes, LFOs, sources, modifiers, the matrix and how it is compiled |
| [6. Script and UI](6-script-and-ui.md) | Parameters, pages, encoders, MIDI, how the UI previews sound |
| [7. Parameter reference](7-parameter-reference.md) | Every engine parameter, range and meaning |
| [8. Performance, testing, extending](8-performance-testing-extending.md) | CPU, how it was checked, how to add a filter / source / destination |

## Honest status

* The engine compiles in SuperCollider 3.13 and every SynthDef renders clean audio offline
  (no NaN, no DC). The Lua side runs under a mock norns. **It has not been run on real norns
  hardware.**
* The filters are *character emulations* built from SuperCollider's stock filters plus
  saturation, not circuit models. Names refer to the sound they aim for, not to a faithful copy.
* Wavetable data and the generators it comes from are © Emilie Gillet, MIT licensed
  (`LICENSE-wavetables.txt`).
