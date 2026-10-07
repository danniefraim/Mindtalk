"""Compare speaker-embedding models on Mindtalk's own meetings (named speakers only)."""
import glob, json, os, sys, time, itertools
import numpy as np, soundfile as sf

ROOT = os.path.expanduser("~/Library/Application Support/Mindtalk/Meetings")
HERE = os.path.dirname(os.path.abspath(__file__))
SR = 16000

def stretches(words, speaker, max_total=30.0):
    st = []
    for i, w in enumerate(words):
        if w.get("speaker") != speaker: continue
        prev = words[i - 1] if i > 0 else None
        if st and prev is not None and prev.get("speaker") == speaker and w["start"] - st[-1][1] < 0.6:
            st[-1][1] = w["end"]
        else:
            st.append([w["start"], w["end"]])
    clean = [(a + 0.15, b - 0.1) for a, b in st if (b - 0.1) - (a + 0.15) >= 0.8]
    chosen, total = [], 0.0
    for s in sorted(clean, key=lambda s: s[1] - s[0], reverse=True):
        chosen.append(s); total += s[1] - s[0]
        if total >= max_total: break
    return sorted(chosen)

def load_items():
    items = []  # (meeting, name, long_audio, [short clips])
    for d in sorted(glob.glob(ROOT + "/*/")):
        mj, au = d + "meeting.json", d + "audio.caf"
        if not (os.path.exists(mj) and os.path.exists(au)): continue
        r = json.load(open(mj))
        names = {int(k): v for k, v in (r.get("names") or {}).items()
                 if v and not v.startswith(("Talare", "Speaker"))}
        if not names: continue
        audio, sr = sf.read(au, dtype="float32")
        assert sr == SR
        for spk, name in names.items():
            parts = [audio[int(a * SR):int(b * SR)] for a, b in stretches(r["words"], spk)]
            if not parts: continue
            x = np.concatenate(parts)
            if len(x) < 6 * SR: continue
            clips = [x[i:i + 4 * SR] for i in range(0, len(x) - 4 * SR + 1, 4 * SR)][:6]
            items.append((os.path.basename(d.rstrip("/"))[:8], name, x[:30 * SR], clips))
    return items

# ---------- models ----------
class CamPP:
    name = "CAM++ (i dag, mandarin)"
    def __init__(self):
        import coremltools as ct
        base = os.path.expanduser("~/Library/Application Support/Mindtalk/Models/campplus-321b18e2/")
        self.pre = ct.models.CompiledMLModel(base + "CamPlusPreprocessor.mlmodelc")
        self.net = ct.models.CompiledMLModel(base + "CamPlusPlus.mlmodelc")
    def embed(self, x):
        f = self.pre.predict({"waveform": (x * 32768.0)[None, :].astype(np.float32)})["features"]
        e = self.net.predict({"feats": f})["embedding"].reshape(-1)
        return e / np.linalg.norm(e)

class Pyannote:
    name = "pyannote community-1"
    def __init__(self):
        import coremltools as ct
        self.fb = ct.models.CompiledMLModel(HERE + "/pyannote/FBank.mlmodelc")
        self.net = ct.models.CompiledMLModel(HERE + "/pyannote/Embedding.mlmodelc")
    def embed(self, x):
        W = 10 * SR; out = []
        for i in range(0, len(x), W):
            seg = x[i:i + W]
            if len(seg) < 2 * SR and out: break
            # A short piece is repeated to fill the window: silence padding skews the
            # features (they are normalised over the whole window).
            pad = np.resize(seg, W).astype(np.float32)
            fb = self.fb.predict({"audio": pad[None, None, :]})["fbank_features"]
            w = np.ones((1, 589), np.float32)
            e = self.net.predict({"fbank_features": fb, "weights": w})["embedding"].reshape(-1)
            out.append(e / np.linalg.norm(e) * len(seg))
        e = np.sum(out, axis=0)
        return e / np.linalg.norm(e)

class ReDim:
    name = "ReDimNet2+"
    def __init__(self):
        import torch
        sys.path.insert(0, HERE + "/redimnet2-plus")
        from asv.models.redimnet2 import ReDimNet2Encoder
        self.torch = torch
        enc = ReDimNet2Encoder(model_name="b6", pretrained=False, train_type="lm", dataset="vox2",
                               model_overrides={"out_channels": 224, "return_2d_output": True})
        sd = torch.load(HERE + "/redimnet/pytorch_model_fsdp.bin", map_location="cpu")
        sd = {k.replace("_orig_mod.", "").replace("module.", ""): v for k, v in sd.items()}
        own = enc.state_dict()
        mapped = {}
        for k, v in sd.items():
            for cand in (k, k.removeprefix("encoder."), "model." + k, "model." + k.removeprefix("encoder.model.")):
                if cand in own and own[cand].shape == v.shape: mapped[cand] = v; break
        missing = [k for k in own if k not in mapped]
        print(f"  ReDimNet2+: {len(mapped)}/{len(own)} vikter laddade, saknas {len(missing)}", missing[:5])
        enc.load_state_dict(mapped, strict=False); enc.eval(); self.enc = enc
    def embed(self, x):
        t = self.torch
        with t.no_grad():
            s = self.enc.spec_frontend(t.from_numpy(x)[None, :])
            e = self.enc(s).reshape(-1).numpy()
        return e / np.linalg.norm(e)

class ReDimCoreML:
    name = "ReDimNet2+ (Core ML, som i appen)"
    def __init__(self):
        import coremltools as ct
        self.m = ct.models.MLModel(HERE + "/ReDimNet2Plus.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
    def embed(self, x):
        W = 10 * SR; out = []
        for i in range(0, len(x), W):
            seg = x[i:i + W]
            if len(seg) < 2 * SR and out: break
            e = self.m.predict({"waveform": np.resize(seg, W).astype(np.float32)[None, :]})["embedding"].reshape(-1)
            out.append(e / np.linalg.norm(e) * len(seg))
        e = np.sum(out, axis=0)
        return e / np.linalg.norm(e)

# ---------- scoring ----------
def eer(tgt, non):
    s = np.concatenate([tgt, non]); y = np.concatenate([np.ones(len(tgt)), np.zeros(len(non))])
    o = np.argsort(-s); y = y[o]
    tp = np.cumsum(y) / len(tgt); fp = np.cumsum(1 - y) / len(non)
    i = np.argmin(np.abs((1 - tp) - fp)); return 100 * ((1 - tp[i]) + fp[i]) / 2

def run(model, items):
    t0 = time.time()
    longs = [model.embed(it[2]) for it in items]
    clips = [[model.embed(c) for c in it[3]] for it in items]
    per_clip = (time.time() - t0) / (len(items) + sum(len(c) for c in clips))
    tgt, non, same_room, ident, gaps = [], [], [], [], []
    skip = {tuple(x.split(":")) for x in os.environ.get("SKIP", "").split(",") if x}
    for i, (m, n, _, _) in enumerate(items):
        for ci, c in enumerate(clips[i]):
            if (m, n, str(ci)) in skip: continue
            best = {}
            for j, (m2, n2, _, _) in enumerate(items):
                if m2 == m: continue
                s = float(c @ longs[j])
                (tgt if n2 == n else non).append(s)
                best[n2] = max(best.get(n2, -1), s)
            for j, (m2, n2, _, _) in enumerate(items):  # another voice in the same meeting (same room, same mic)
                if m2 == m and n2 != n: same_room.append(float(c @ longs[j]))
            if n in best and len(best) > 1:
                others = max(v for k, v in best.items() if k != n)
                ident.append(best[n] > others); gaps.append(best[n] - others)
    return dict(tgt=np.array(tgt), non=np.array(non), room=np.array(same_room),
                acc=np.mean(ident), gap=np.median(gaps), worst=np.min(gaps), ms=per_clip * 1000)

if __name__ == "__main__":
    items = load_items()
    from collections import Counter
    print("Testdata:", len(items), "personer-i-möten,", sum(len(i[3]) for i in items), "korta bitar à 4 s,",
          dict(Counter(i[1] for i in items)))
    for M in (CamPP, Pyannote, ReDim, ReDimCoreML):
        try:
            model = M(); r = run(model, items)
        except Exception as e:
            print(M.name, "FEL:", repr(e)); continue
        print(f"\n== {M.name}")
        print(f"  samma person (andra möten):   medel {r['tgt'].mean():.2f}  (lägsta {r['tgt'].min():.2f})")
        print(f"  olika personer (andra möten): medel {r['non'].mean():.2f}  (högsta {r['non'].max():.2f})")
        print(f"  annan röst i samma rum:       medel {r['room'].mean():.2f}  (högsta {r['room'].max():.2f})")
        print(f"  EER 4 s mot avtryck:          {eer(r['tgt'], np.concatenate([r['non'], r['room']])):.1f} %")
        print(f"  rätt person bäst:             {100*r['acc']:.0f} %   marginal median {r['gap']:.2f}, sämsta {r['worst']:.2f}")
        print(f"  tid per bit:                  {r['ms']:.0f} ms")
