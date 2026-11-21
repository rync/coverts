"""Render the Sheep and Plaits wavetables to 16-bit mono WAVs for norns.
Each file = N waves laid end to end, 257 frames per wave (256 + wrap point).
Run with cwd = a checkout of github.com/pichenettes/eurorack (MIT-licensed data)."""
import sys, os, wave, importlib.util
import numpy as np
gen_dir, out_dir = sys.argv[1], sys.argv[2]
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(gen_dir, name + '.py'))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
def to257(w, n_src):
    w = np.asarray(w, dtype=np.float64)[:n_src]
    if n_src != 256:                      # periodic resample to 256 via FFT
        w = np.fft.irfft(np.fft.rfft(w), 256) 
    w = w - w.mean(); w = w / max(np.abs(w).max(), 1e-9)
    return np.append(w, w[0])             # wrap point for interpolation
def write(name, waves):
    data = np.concatenate(waves)
    pcm = np.round(np.clip(data, -1, 1) * 32767).astype('<i2')
    with wave.open(os.path.join(out_dir, name), 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(48000); f.writeframes(pcm.tobytes())
    print(name, len(waves), 'waves', len(pcm), 'frames')
p = load('plaits_gen')
for i, b in enumerate([p.bank_1, p.bank_2, p.bank_3], 1):
    write('plaits_%d.wav' % i, [to257(w, 256) for w in b])
s = load('sheep_gen')
b3 = np.array(s.bank_3, dtype=np.float64)[:50 * 257].reshape(50, 257)
def split(bank): return [np.asarray(bank[k*257:(k+1)*257], dtype=np.float64) for k in range(len(bank)//257)]
write('sheep_1.wav', [to257(w[:256], 256) for w in split(s.make_bank(s.bank_1))])
write('sheep_2.wav', [to257(w[:256], 256) for w in split(s.make_bank(s.bank_2))])
write('sheep_3.wav', [to257(w[:256], 256) for w in b3])
