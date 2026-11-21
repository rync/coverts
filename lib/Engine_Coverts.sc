// Engine_Coverts
// A polyphonic, wavetable synth voice for monome norns, inspired by the Mutable
// Instruments Shruthi-1 and Ambika.
//
//  * 2 oscillators per voice (off / saw / pulse / triangle / sine / wavetable)
//  * 14 wavetable banks (Sheep, Plaits, and generated "in the style of" sets), each
//    cut into tables of 8 waves
//  * x-mod section (sync / ring / fold / crush), sub oscillator and noise
//  * seven selectable filter models
//  * 3 ADSR envelopes (with curve), 4 LFOs (19 shapes, delay + fade-in each),
//    a 14-slot modulation matrix with 21 destinations, and 4 modifiers
//
// Architecture (see docs/): every parameter lives in ONE patch synth that smooths it
// once and writes it to a control bus; voices only read that bus. A note therefore
// costs one small s_new, and a knob move costs one message, however many voices play.
//
// Wavetable data and the generators it is derived from are (c) Emilie Gillet,
// MIT licensed. See LICENSE-wavetables.txt.

Engine_Coverts : CroneEngine {

	classvar <nDest = 21;     // matrix destinations
	classvar <nIn = 3;        // inputs per destination

	var <voices;        // List of Events (syn, note, held, sus)
	var <pnames;        // parameter names, in bus order
	var <pidx;          // name -> bus index
	var <pvals;         // name -> current value
	var <pdefs;         // [name, default, lagTime]
	var <parBus;        // every smoothed parameter, read by voices and the LFO synth
	var <patchSyn;
	var <bufs;          // wavetable buffers
	var <nwaves;        // waves in each buffer (from the file length)
	var <lfoBuf;        // table-based LFO shapes
	var <ctlBus;        // bend, mod wheel, pressure, lfo1-3
	var <lfoSynth;
	var <pg;            // voice group
	var <defNames;      // one SynthDef per filter model
	var <filterIdx;
	var <maxVoices;
	var <sustainOn;
	var <lastNote;
	var <voiceBus;      // voices sum here; the master synth limits and outputs
	var <master;
	var <diagBus;       // limiter diagnostics
	var <diagVal;
	var <steals;
	var <ctlVals;
	var patchArgs;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// ------------------------------------------------------------------
	// parameter registry: [name, default, smoothing time or nil]
	// ------------------------------------------------------------------
	makeParams {
		var l = List.new;
		var add = { arg n, d, t = nil; l.add([n.asSymbol, d, t]) };

		// wavetable selection (set by setBank)
		add.(\buf1, 0); add.(\nw1, 64); add.(\off1, 0);
		add.(\buf2, 0); add.(\nw2, 64); add.(\off2, 0);
		add.(\lbuf, 0);
		// oscillators
		add.(\shape1, 0); add.(\shape2, 0);
		add.(\pos1, 0, 0.03); add.(\pos2, 0, 0.03);
		add.(\range1, 0); add.(\range2, 0);
		add.(\tune1, 0, 0.03); add.(\tune2, 0, 0.03);
		add.(\balance, 0.5, 0.03); add.(\xmode, 0); add.(\xamt, 0, 0.03);
		add.(\sublevel, 0, 0.03); add.(\subshape, 0); add.(\noise, 0, 0.03);
		add.(\drive, 0, 0.03);
		// filter
		add.(\cutoff, 16000, 0.02); add.(\res, 0, 0.03); add.(\fmode, 0, 0.03);
		add.(\fextra, 0, 0.03); add.(\fpar, 0);
		add.(\ktrack, 0, 0.03); add.(\fenv, 0, 0.03);
		// envelopes
		add.(\a1, 0.005); add.(\d1, 0.4); add.(\s1, 0); add.(\r1, 0.4); add.(\cv1, -4);
		add.(\a2, 0.005); add.(\d2, 0.5); add.(\s2, 1); add.(\r2, 0.3); add.(\cv2, -4);
		add.(\a3, 0.005); add.(\d3, 0.5); add.(\s3, 0); add.(\r3, 0.4); add.(\cv3, -4);
		// LFOs: shape, rate (Hz), slew, scope (0 shared / 1 voice), sync (0 free / 1 key), delay, fade
		add.(\l1shape, 0); add.(\l1rate, 1, 0.05); add.(\l1slew, 0); add.(\l1scope, 0); add.(\l1sync, 1); add.(\l1delay, 0); add.(\l1fade, 0);
		add.(\l2shape, 5); add.(\l2rate, 5, 0.05); add.(\l2slew, 0); add.(\l2scope, 0); add.(\l2sync, 1); add.(\l2delay, 0); add.(\l2fade, 0);
		add.(\l3shape, 0); add.(\l3rate, 1, 0.05); add.(\l3slew, 0); add.(\l3scope, 0); add.(\l3sync, 1); add.(\l3delay, 0); add.(\l3fade, 0);
		add.(\l4shape, 0); add.(\l4rate, 4, 0.05); add.(\l4slew, 0); add.(\l4sync, 1); add.(\l4delay, 0); add.(\l4fade, 0);
		// modifiers
		4.do { arg i;
			add.(("x" ++ (i + 1) ++ "a"), 0); add.(("x" ++ (i + 1) ++ "b"), 0);
			add.(("x" ++ (i + 1) ++ "op"), 0); add.(("x" ++ (i + 1) ++ "p"), 0.3);
		};
		// voice
		add.(\bendrange, 2); add.(\drift, 0); add.(\spread, 0, 0.03); add.(\glide, 0);
		add.(\velamt, 0); add.(\amp, 0.78, 0.05); add.(\pan, 0, 0.03);
		// compiled modulation matrix: source index and amount per destination input
		nDest.do { arg d;
			nIn.do { arg j;
				add.(("d" ++ (d + 1) ++ "s" ++ (j + 1)), 0);
				add.(("d" ++ (d + 1) ++ "a" ++ (j + 1)), 0, 0.03);
			};
		};
		^l.asArray
	}

	// LFO shapes that are read from a table (indices 7 and up in the LFO shape list)
	makeLfoTable {
		var n = 257, shapes, tri, bump;
		tri = { arg t; 1 - (4 * ((t % 1) - 0.25).abs) };
		bump = { arg t, c, w; (-1 * (((t - c) / w).squared)).exp };
		shapes = [
			{ arg t; (tri.(t) * 1.6).clip(-1, 1) },                                   // 7  TRAPEZ
			{ arg t; (4 * sin(2pi * t)).tanh / 4.tanh },                               // 8  RND SQR
			{ arg t; (((4 * t).exp - 1) / (4.exp - 1) * 2) - 1 },                      // 9  EXP UP
			{ arg t; (((-4 * t).exp - (-4).exp) / (1 - (-4).exp) * 2) - 1 },          // 10 EXP DN
			{ arg t; (2 * sin(4pi * t).abs) - 1 },                                     // 11 BOUNCE
			{ arg t; (sin(2pi * t) + (0.5 * sin(4pi * t))) / 1.3 },                    // 12 DBL SIN
			{ arg t; ((bump.(t, 0.1, 0.045) + (0.6 * bump.(t, 0.3, 0.055))).min(1) * 2) - 1 },  // 13 HEART
			{ arg t; if(t < 0.25) { 1 } { -1 } },                                      // 14 PULSE25
			{ arg t; ((t * 4).floor / 3 * 2) - 1 },                                    // 15 STEP 4
			{ arg t; 1 - ((t * 8).floor / 7 * 2) },                                    // 16 STEP 8
			{ arg t; [0.8, -0.3, 0.2, -0.9, 0.5, -0.6, 0.9, 0.0][(t * 8).floor.clip(0, 7).asInteger] },     // 17 STEP A
			{ arg t; [-1, -0.3, 0.3, 1, 0.3, -0.3, -0.7, 0][(t * 8).floor.clip(0, 7).asInteger] }           // 18 STEP B
		];
		^FloatArray.newFrom(shapes.collect { arg f;
			n.collect { arg i; f.(((i % 256) / 256)).asFloat }
		}.flatten)
	}

	// ------------------------------------------------------------------
	// SynthDefs
	// ------------------------------------------------------------------
	buildDefs {
		var filters, makeDef, lfoFn, nP = pnames.size, pl, lfoShape;

		// Each filter: { |sig, cut, res, mode, extra, par| ... }
		// cut = Hz, res / mode / extra = 0..1, par = 0 or 1

		filters = [

			// NOTE: BLowPass / BHiPass (RBJ biquads) are used instead of RLPF / RHPF because the
			// latter's response collapses above ~6 kHz (its tan() mapping runs out of range).
			// 0 - SMR4 mkII: round, slightly overdriven 4-pole low-pass ladder
			{ arg sig, cut, res, mode, extra, par;
				var x = MoogFF.ar(sig, cut, res * 3.9);
				x * (1 + (res * 0.8))
			},

			// 1 - 4-Pole Mission: pole-mixing, morphs LP4 -> BP4 -> HP4
			{ arg sig, cut, res, mode, extra, par;
				var rq1 = 0.9;
				var rq2 = (1 - (res * 0.92)).max(0.06);
				var s1, s2;
				s1 = SelectX.ar(mode * 2, [
					BLowPass.ar(sig, cut, rq1),
					BPF.ar(sig, cut, rq1) * 1.6,
					BHiPass.ar(sig, cut, rq1)
				]);
				s2 = SelectX.ar(mode * 2, [
					BLowPass.ar(s1, cut, rq2),
					BPF.ar(s1, cut, rq2) * 1.6,
					BHiPass.ar(s1, cut, rq2)
				]);
				s2
			},

			// 2 - Dual SVF: two 2-pole multimode filters, series or parallel
			{ arg sig, cut, res, mode, extra, par;
				var rq = (1 - (res * 0.93)).max(0.07);
				var cutB = (cut * (2 ** ((extra * 4) - 2))).clip(20, 16000);
				var a, b, serial, parallel;
				a = SelectX.ar(mode * 2, [
					BLowPass.ar(sig, cut, rq),
					BPF.ar(sig, cut, rq) * 1.6,
					BHiPass.ar(sig, cut, rq)
				]);
				b = SelectX.ar(mode * 2, [
					BLowPass.ar(a, cutB, rq),
					BPF.ar(a, cutB, rq) * 1.6,
					BHiPass.ar(a, cutB, rq)
				]);
				// parallel: second filter reads the dry input
				serial = b;
				parallel = (a + SelectX.ar(mode * 2, [
					BLowPass.ar(sig, cutB, rq),
					BPF.ar(sig, cutB, rq) * 1.6,
					BHiPass.ar(sig, cutB, rq)
				])) * 0.6;
				XFade2.ar(serial, parallel, (par * 2) - 1)
			},

			// 3 - Polivoks: 2-pole LP/BP with harsh distortion
			{ arg sig, cut, res, mode, extra, par;
				var x = (sig * 1.5).tanh;
				var rq = (1 - (res * 0.9)).max(0.1);
				var y = SelectX.ar(mode, [
					BLowPass.ar(x, cut, rq),
					BPF.ar(x, cut, rq) * 2
				]);
				((y * (1 + (extra * 6))).tanh) * 0.8
			},

			// 4 - MS-20 style: HPF into a nonlinear 2-pole LPF
			{ arg sig, cut, res, mode, extra, par;
				var hp = HPF.ar(sig, (cut * extra * 0.9).max(20));
				var x = (hp * 1.3).tanh;
				var y = BLowPass.ar(x, cut, (1 - (res * 0.95)).max(0.05));
				((y * (1 + res)).tanh) * 0.9
			},

			// 5 - Digital: crunchy LP/HP followed by bit reduction
			{ arg sig, cut, res, mode, extra, par;
				var rq = (1 - (res * 0.9)).max(0.1);
				var y = SelectX.ar(mode, [
					BLowPass.ar(sig, cut, rq),
					BHiPass.ar(sig, cut, rq)
				]);
				var steps = 2 ** (12 - (extra * 9));
				(y * steps).round(1.0) / steps
			},

			// 6 - Prophet VS style: clean, OTA-like 24 dB low-pass (Curtis CEM family)
			//     mode  = pole switch (0 = 4-pole, 1 = 2-pole)
			//     extra = bass compensation (keeps the low end as resonance rises)
			{ arg sig, cut, res, mode, extra, par;
				var x = (sig * 0.9).tanh;
				var rq4 = (0.77 - (res * 0.73)).max(0.04);     // res 0 ~ Butterworth, res 1 ~ self-oscillation
				var rq2 = (1 - (res * 0.96)).max(0.04);
				var s1 = BLowPass.ar(x, cut, 1.85);
				var s2 = BLowPass.ar((s1 * 1.1).tanh, cut, rq4);
				var p2 = BLowPass.ar(x, cut, rq2);
				var y = XFade2.ar(s2, p2, (mode * 2) - 1);
				var bass = LPF.ar(x, 140) * res * extra * 0.9;
				((y + bass) * 0.9).tanh
			}
		];



		// LFO shapes 0-6 are computed, 7+ are read from the table in lfoBuf:
		// 0 tri, 1 ramp up, 2 square, 3 s&h, 4 smooth random, 5 sine, 6 ramp down, 7+ table
		lfoFn = { arg shape, rate, ph0, lb;
			var tbl = BufRd.kr(1, lb,
				((shape - 7).max(0) * 257) + (((LFSaw.kr(rate, ph0 * 2) + 1) * 0.5) * 256), 0, 2);
			Select.kr(shape.min(7), [
				LFTri.kr(rate, ph0 * 4),
				LFSaw.kr(rate, ph0 * 2),
				(LFPulse.kr(rate, ph0) * 2) - 1,
				LFNoise0.kr(rate),
				LFNoise1.kr(rate),
				SinOsc.kr(rate, ph0 * 2pi),
				LFSaw.kr(rate, ph0 * 2) * -1,
				tbl
			])
		};

		// patch: every parameter, smoothed once, written to the parameter bus
		SynthDef(\coverts_patch, {
			arg parbus = 0;
			var vals = pdefs.collect { arg e;
				var c = NamedControl.kr(e[0], e[1]);
				if(e[2].notNil) { Lag.kr(c, e[2]) } { c }
			};
			Out.kr(parbus, vals);
		}).add;

		// LFO 1-3, patch level (shared by all voices), written to the control bus
		SynthDef(\coverts_lfo, {
			arg parbus = 0, busnum = 0;
			var pv = In.kr(parbus, nP);
			var p = { arg n; pv[pidx[n]] };
			var a, b, c;
			a = Lag.kr(lfoFn.(p.(\l1shape), p.(\l1rate), 0, p.(\lbuf)), p.(\l1slew) * 0.25);
			b = Lag.kr(lfoFn.(p.(\l2shape), p.(\l2rate), 0, p.(\lbuf)), p.(\l2slew) * 0.25);
			c = Lag.kr(lfoFn.(p.(\l3shape), p.(\l3rate), 0, p.(\lbuf)), p.(\l3slew) * 0.25);
			Out.kr(busnum + 3, [a, b, c]);
		}).add;

		// master: voices sum here; gain falls with the number of sounding voices (equal-power),
		// then a look-ahead limiter catches whatever is left. diag = [level in, level out].
		SynthDef(\coverts_master, {
			arg inb = 0, out = 0, nv = 1, diag = 0;
			var pre = In.ar(inb, 2) * Lag.kr((2 / nv.max(2)).sqrt, 0.15);
			var post = Limiter.ar(pre, 0.9, 0.01);
			Out.kr(diag, [
				Amplitude.kr(pre[0].abs.max(pre[1].abs), 0.002, 0.2),
				Amplitude.kr(post[0].abs.max(post[1].abs), 0.002, 0.2)
			]);
			Out.ar(out, post);
		}).add;

		makeDef = { arg name, filt;
			SynthDef(name, {
				arg out = 0, gate = 1, note = 60, lastnote = 60, vel = 0.8, busnum = 0, parbus = 0;

				var pv = In.kr(parbus, nP);
				var p = { arg n; pv[pidx[n]] };
				var busv, bendN, mw, at, env1, env2, env3, rndv, rndpan, n0, keyt;
				var lprev, baseR, srcsR, mkdm, dRate, dm, dsel;
				var privLfo, onset, scopeOf, lfo1, lfo2, lfo3, lfo4;
				var base, pick, modv, srcs;
				var f1, f2, pos1m, pos2m, ph1, ph2, issync, syncTrig;
				var wt, o1, o2, bal, xa, ring, o12, steps, crushed, xm;
				var sub, sublv, nzlv, drv, sig, cutOct, cutHz, resm, fsig, vca, panv;

				busv = In.kr(busnum, 6);
				bendN = busv[0];
				mw = busv[1];
				at = busv[2];

				// --- three ADSR envelopes with adjustable curve ---
				env1 = EnvGen.kr(Env.adsr(p.(\a1).max(0.001), p.(\d1).max(0.001), p.(\s1), p.(\r1).max(0.001), 1, p.(\cv1)), gate);
				env2 = EnvGen.kr(Env.adsr(p.(\a2).max(0.001), p.(\d2).max(0.001), p.(\s2), p.(\r2).max(0.001), 1, p.(\cv2)), gate, doneAction: 2);
				env3 = EnvGen.kr(Env.adsr(p.(\a3).max(0.001), p.(\d3).max(0.001), p.(\s3), p.(\r3).max(0.001), 1, p.(\cv3)), gate);
				rndv = Rand(-1.0, 1.0);
				rndpan = Rand(-1.0, 1.0);

				// --- pitch ---
				n0 = Line.kr(lastnote, note, p.(\glide).max(0.001)) + (bendN * p.(\bendrange));
				keyt = (n0 - 60) / 60;

				// --- modulation matrix ---
				// 14 user slots are compiled by the script into 21 destinations x 3 inputs.
				mkdm = { arg di, arr;
					Mix.new(3.collect { arg j;
						Select.kr(p.(("d" ++ (di + 1) ++ "s" ++ (j + 1)).asSymbol), arr)
						* p.(("d" ++ (di + 1) ++ "a" ++ (j + 1)).asSymbol)
					})
				};
				// LFO-rate destinations (18-21) read the LFOs of the previous control block, so an
				// LFO can modulate another's rate (or its own) without a feedback loop; the
				// modifier sources (OP1-4) are not available for them.
				lprev = LocalIn.kr(4);
				baseR = [0, env1, env2, env3, lprev[0], lprev[1], lprev[2], lprev[3],
					vel, mw, at, keyt, rndv, bendN, 1];
				srcsR = baseR ++ [0, 0, 0, 0];
				dRate = 4.collect { arg k; mkdm.(17 + k, srcsR) };

				// --- LFOs 1-4: 1-3 shared (control bus) or per voice, 4 per voice; each has
				// delay + fade-in. A rate-modulated LFO always runs per voice. ---
				privLfo = { arg k, rmod;
					var kk = k.asString;
					var rate = (p.(("l" ++ kk ++ "rate").asSymbol) * (2 ** (rmod * 4))).clip(0.01, 100);
					var sync = p.(("l" ++ kk ++ "sync").asSymbol);
					Lag.kr(lfoFn.(p.(("l" ++ kk ++ "shape").asSymbol), rate,
						(1 - sync) * Rand(0.0, 1.0), p.(\lbuf)), p.(("l" ++ kk ++ "slew").asSymbol) * 0.25)
				};
				onset = { arg k;
					var kk = k.asString;
					EnvGen.kr(Env([0, 0, 1], [p.(("l" ++ kk ++ "delay").asSymbol).max(0.001),
						p.(("l" ++ kk ++ "fade").asSymbol).max(0.001)]))
				};
				scopeOf = { arg k;
					var kk = k.asString;
					var da = 17 + k;
					max(p.(("l" ++ kk ++ "scope").asSymbol),
						((p.(("d" ++ da ++ "a1").asSymbol).abs + p.(("d" ++ da ++ "a2").asSymbol).abs
							+ p.(("d" ++ da ++ "a3").asSymbol).abs) > 0.001))
				};
				lfo1 = Select.kr(scopeOf.(1), [busv[3], privLfo.(1, dRate[0])]) * onset.(1);
				lfo2 = Select.kr(scopeOf.(2), [busv[4], privLfo.(2, dRate[1])]) * onset.(2);
				lfo3 = Select.kr(scopeOf.(3), [busv[5], privLfo.(3, dRate[2])]) * onset.(3);
				lfo4 = privLfo.(4, dRate[3]) * onset.(4);
				LocalOut.kr([lfo1, lfo2, lfo3, lfo4]);

				// --- 15 base sources, 4 modifiers that combine two of them ---
				base = [0, env1, env2, env3, lfo1, lfo2, lfo3, lfo4, vel, mw, at, keyt, rndv, bendN, 1];
				pick = { arg a, b, op, pp;
					var va = Select.kr(a, base);
					var vb = Select.kr(b, base);
					Select.kr(op, [
						va * vb,
						(va + vb) * 0.5,
						min(va, vb),
						max(va, vb),
						Lag.kr(va, pp * 3),
						Latch.kr(va, vb > 0.5)
					])
				};
				modv = [
					pick.(p.(\x1a), p.(\x1b), p.(\x1op), p.(\x1p)),
					pick.(p.(\x2a), p.(\x2b), p.(\x2op), p.(\x2p)),
					pick.(p.(\x3a), p.(\x3b), p.(\x3op), p.(\x3p)),
					pick.(p.(\x4a), p.(\x4b), p.(\x4op), p.(\x4p))
				];
				srcs = base ++ modv;
				dm = 17.collect { arg di; mkdm.(di, srcs) };
				// dsel.(1..17) = POS1 ... FEXTRA
				dsel = { arg d; dm[d - 1] };

				f1 = (n0 + p.(\range1) + (p.(\tune1) * 0.01) + ((dsel.(4) + dsel.(6)) * 12)
					+ (LFNoise1.kr(0.37) * p.(\drift) * 0.15)).midicps.clip(8, 18000);
				f2 = (n0 + p.(\range2) + (p.(\tune2) * 0.01) + ((dsel.(5) + dsel.(6)) * 12)
					+ (LFNoise1.kr(0.41) * p.(\drift) * 0.15)).midicps.clip(8, 18000);
				pos1m = Lag.ar(K2A.ar((p.(\pos1) + dsel.(1) + dsel.(3)).clip(0, 1)), 0.004);
				pos2m = Lag.ar(K2A.ar((p.(\pos2) + dsel.(2) + dsel.(3)).clip(0, 1)), 0.004);

				// --- wavetable reader: crossfades between neighbouring waves ---
				// pos is audio-rate (smoothed above), so scanning never steps at control rate;
				// off = first wave of the selected table inside the bank buffer
				wt = { arg buf, nw, off, pos, ph;
					var wp = pos * (nw - 1);
					var w0 = wp.floor;
					var fr = wp - w0;
					var w1 = (w0 + 1).min(nw - 1);
					var i0 = ((w0 + off) * 257) + (ph * 256);
					var i1 = ((w1 + off) * 257) + (ph * 256);
					(BufRd.ar(1, buf, i0, 0, 2) * (1 - fr)) + (BufRd.ar(1, buf, i1, 0, 2) * fr)
				};

				issync = InRange.kr(p.(\xmode), 0.5, 1.5);
				ph1 = Phasor.ar(0, f1 * SampleDur.ir, 0, 1);
				syncTrig = (HPZ1.ar(ph1) < 0) * issync;
				ph2 = Phasor.ar(syncTrig, f2 * SampleDur.ir, 0, 1);

				// shape: 0 saw, 1 pulse, 2 triangle, 3 sine, 4 wavetable, 5 off
				o1 = Select.ar(p.(\shape1), [
					Saw.ar(f1),
					Pulse.ar(f1, pos1m.clip(0.04, 0.96)),
					(((ph1 * 2) - 1).abs * 2) - 1,
					SinOsc.ar(0, ph1 * 2pi),
					wt.(p.(\buf1), p.(\nw1), p.(\off1), pos1m, ph1),
					DC.ar(0)
				]);
				o2 = Select.ar(p.(\shape2), [
					Select.ar(issync, [Saw.ar(f2), SyncSaw.ar(f1, f2)]),
					Pulse.ar(f2, pos2m.clip(0.04, 0.96)),
					(((ph2 * 2) - 1).abs * 2) - 1,
					SinOsc.ar(0, ph2 * 2pi),
					wt.(p.(\buf2), p.(\nw2), p.(\off2), pos2m, ph2),
					DC.ar(0)
				]);

				// --- oscillator mix and x-mod ---
				bal = (p.(\balance) + (dsel.(7) * 0.5)).clip(0, 1);
				xa = (p.(\xamt) + (dsel.(13) * 0.5)).clip(0, 1);
				o12 = XFade2.ar(o1, o2, (bal * 2) - 1);
				ring = o1 * o2;
				steps = 2 ** (11 - (xa * 8));
				crushed = Latch.ar(
					(o12 * steps).round(1.0) / steps,
					Impulse.ar(SampleRate.ir * ((1 - xa).squared).max(0.03))
				);
				xm = Select.ar(p.(\xmode), [
					o12,
					o12,
					XFade2.ar(o12, ring * 1.4, (xa * 2) - 1),
					(o12 * (1 + (xa * 6))).fold2(1),
					crushed
				]);

				// --- sub oscillator and noise ---
				sublv = (p.(\sublevel) + (dsel.(10) * 0.5)).clip(0, 1);
				nzlv = (p.(\noise) + (dsel.(11) * 0.5)).clip(0, 1);
				sub = Select.ar(p.(\subshape), [
					Pulse.ar(f1 * 0.5, 0.5),
					Pulse.ar(f1 * 0.25, 0.5),
					SinOsc.ar(f1 * 0.5),
					SinOsc.ar(f1 * 0.25)
				]);
				sig = (xm * 0.7) + (sub * sublv * 0.5) + (WhiteNoise.ar * nzlv * 0.5);

				// --- drive and filter ---
				drv = (p.(\drive) + (dsel.(15) * 0.5)).clip(0, 1);
				sig = (sig * (1 + (drv * 5))).tanh * 0.8;

				cutOct = (dsel.(8) * 5) + (env1 * p.(\fenv) * 6) + (((n0 - 60) / 12) * p.(\ktrack));
				cutHz = (p.(\cutoff) * (2 ** cutOct)).clip(20, 16000);
				resm = (p.(\res) + (dsel.(9) * 0.5)).clip(0, 1);
				fsig = filt.value(sig, cutHz, resm,
					(p.(\fmode) + (dsel.(16) * 0.5)).clip(0, 1),
					(p.(\fextra) + (dsel.(17) * 0.5)).clip(0, 1),
					p.(\fpar));
				fsig = LeakDC.ar(fsig);

				// --- amplifier ---
				vca = env2 * ((1 - p.(\velamt)) + (p.(\velamt) * vel)) * ((1 + dsel.(12)).max(0)) * p.(\amp);
				panv = (p.(\pan) + dsel.(14) + (rndpan * p.(\spread))).clip(-1, 1);
				Out.ar(out, Pan2.ar((fsig * vca).softclip, panv));
			}).add;
		};

		defNames = filters.collect { arg f, i;
			var nm = ("coverts_" ++ i).asSymbol;
			makeDef.value(nm, f);
			nm
		};
	}

	// ------------------------------------------------------------------
	// voices
	// ------------------------------------------------------------------
	updateMaster {
		if(master.notNil) { master.set(\nv, voices.size) };
	}

	killVoice { arg ev;
		ev[\syn].set(\gate, -1.02);   // forced 20 ms release, node frees itself
		voices.removeAllSuchThat { arg x; x === ev };
		this.updateMaster;
	}

	releaseVoice { arg ev;
		ev[\syn].set(\gate, 0);
		ev[\held] = false;
		ev[\sus] = false;
	}

	noteOn { arg n, v;
		var ev, syn, victim, args;

		// the same note retriggers
		voices.copy.do { arg x;
			if(x[\note] == n) { this.killVoice(x) };
		};

		// steal: prefer a releasing voice, then the oldest
		while { voices.size >= maxVoices } {
			victim = voices.detect { arg x; x[\held].not };
			if(victim.isNil) { victim = voices[0] };
			steals = steals + 1;
			this.killVoice(victim);
		};

		args = [
			\out, voiceBus.index,
			\busnum, ctlBus.index,
			\parbus, parBus.index,
			\note, n,
			\lastnote, lastNote,
			\vel, v,
			\gate, 1
		];
		syn = Synth.new(defNames[filterIdx], args, pg);
		ev = (syn: syn, note: n, held: true, sus: false);
		voices.add(ev);
		this.updateMaster;
		NodeWatcher.register(syn);
		syn.onFree({ voices.removeAllSuchThat({ arg x; x === ev }); this.updateMaster });
		lastNote = n;
	}

	noteOff { arg n;
		voices.copy.do { arg x;
			if((x[\note] == n) && x[\held]) {
				if(sustainOn) { x[\sus] = true } { this.releaseVoice(x) };
			};
		};
	}

	setSustain { arg on;
		sustainOn = (on > 0);
		if(sustainOn.not) {
			voices.copy.do { arg x;
				if(x[\sus]) { this.releaseVoice(x) };
			};
		};
	}

	allOff {
		voices.copy.do { arg x;
			if(x[\held]) { this.releaseVoice(x) };
		};
		sustainOn = false;
	}

	// one message to the patch synth updates every voice
	setParam { arg key, val;
		if(pidx.includesKey(key)) {
			pvals[key] = val;
			patchSyn.set(key, val);
		};
	}

	// tab 0 = the whole bank; tab 1..N = one table of 8 waves (the last table of a bank
	// whose size is not a multiple of 8 takes the remainder). N = waves div 8.
	setBank { arg osc, bank, tab = 0;
		var i = (bank - 1).clip(0, bufs.size - 1);
		var n = nwaves[i];
		var ntabs = (n div: 8).max(1);
		var t = (tab - 1).clip(0, ntabs - 1);
		var off = 0, cnt = n;
		if(tab > 0) {
			off = t * 8;
			cnt = if(t == (ntabs - 1)) { n - off } { 8 };
		};
		this.setParam(("buf" ++ osc).asSymbol, bufs[i].bufnum);
		this.setParam(("nw" ++ osc).asSymbol, cnt);
		this.setParam(("off" ++ osc).asSymbol, off);
	}

	loadWaves {
		var dir = PathName(Engine_Coverts.filenameSymbol.asString).pathOnly ++ "../waves/";
		var names = ["sheep_1", "sheep_2", "sheep_3", "plaits_1", "plaits_2", "plaits_3",
			"ambika_1", "ambika_2", "blofeld_1", "blofeld_2", "ppg_1", "ppg_2", "provs_1", "provs_2"];
		bufs = names.collect { arg n;
			Buffer.read(context.server, dir ++ n ++ ".wav")
		};
		lfoBuf = Buffer.sendCollection(context.server, this.makeLfoTable, 1);
		context.server.sync;
		nwaves = bufs.collect { arg b; b.numFrames div: 257 };
		("Coverts: " ++ bufs.size ++ " wavetable banks loaded from " ++ dir).postln;
	}

	// parameter registry + SynthDefs (also used by the offline test harness)
	prepDefs {
		pdefs = this.makeParams;
		pnames = pdefs.collect { arg e; e[0] };
		pidx = Dictionary.new;
		pvals = Dictionary.new;
		pdefs.do { arg e, i; pidx[e[0]] = i; pvals[e[0]] = e[1] };
		this.buildDefs;
	}

	// ------------------------------------------------------------------
	alloc {
		voices = List.new;
		maxVoices = 6;
		sustainOn = false;
		lastNote = 60;
		filterIdx = 0;
		steals = 0;
		diagVal = [0, 0];
		ctlVals = [0, 0, 0];
		ctlBus = Bus.control(context.server, 6);
		ctlBus.setn(ctlVals);
		voiceBus = Bus.audio(context.server, 2);
		diagBus = Bus.control(context.server, 2);

		this.prepDefs;
		parBus = Bus.control(context.server, pnames.size);
		this.loadWaves;
		pvals[\lbuf] = lfoBuf.bufnum;
		context.server.sync;

		patchArgs = [\parbus, parBus.index];
		pvals.keysValuesDo { arg k, val; patchArgs = patchArgs ++ [k, val] };
		patchSyn = Synth.head(context.xg, \coverts_patch, patchArgs);
		lfoSynth = Synth.after(patchSyn, \coverts_lfo, [\parbus, parBus.index, \busnum, ctlBus.index]);
		pg = ParGroup.tail(context.xg);
		master = Synth.after(pg, \coverts_master,
			[\inb, voiceBus.index, \out, context.out_b.index, \diag, diagBus.index]);
		context.server.sync;
		this.setBank(1, 4, 0);
		this.setBank(2, 4, 0);

		// ---- commands ----
		this.addCommand("note_on", "if", { arg msg; this.noteOn(msg[1], msg[2]) });
		this.addCommand("note_off", "i", { arg msg; this.noteOff(msg[1]) });
		this.addCommand("sustain", "i", { arg msg; this.setSustain(msg[1]) });
		this.addCommand("all_off", "", { arg msg; this.allOff });
		this.addCommand("bend", "f", { arg msg; ctlVals[0] = msg[1]; ctlBus.setn(ctlVals) });
		this.addCommand("modwheel", "f", { arg msg; ctlVals[1] = msg[1]; ctlBus.setn(ctlVals) });
		this.addCommand("pressure", "f", { arg msg; ctlVals[2] = msg[1]; ctlBus.setn(ctlVals) });
		this.addCommand("pset", "sf", { arg msg; this.setParam(msg[1].asSymbol, msg[2]) });
		this.addCommand("osc_bank", "iii", { arg msg; this.setBank(msg[1], msg[2], msg[3]) });
		this.addCommand("ftype", "i", { arg msg; filterIdx = msg[1].clip(0, defNames.size - 1) });
		this.addCommand("poly", "i", { arg msg; maxVoices = msg[1].clip(1, 12) });

		// ---- diagnostics (read by the VOICE page) ----
		this.addPoll(\voices, { voices.size });
		this.addPoll(\steals, { steals });
		this.addPoll(\limiter, {
			var pre, post;
			diagBus.getn(2, { arg v; diagVal = v });
			pre = diagVal[0].max(0.0001);
			post = diagVal[1].max(0.0001);
			(20 * (pre / post).log10).max(0)
		});
	}

	free {
		voices.do { arg x; x[\syn].free };
		bufs.do { arg b; b.free };
		lfoBuf.free;
		patchSyn.free;
		lfoSynth.free;
		master.free;
		voiceBus.free;
		diagBus.free;
		parBus.free;
		ctlBus.free;
		pg.free;
	}
}
