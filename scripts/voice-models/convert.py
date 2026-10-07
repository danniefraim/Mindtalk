import sys, time, numpy as np, torch, coremltools as ct
sys.path.insert(0, "redimnet2-plus")
from bench import ReDim, load_items
from asv.models.redimnet2_vendor import redimnet2 as vendor

r = ReDim()
items = load_items()
def fill(x): return np.resize(x, 160000).astype(np.float32)
xs = [items[0][3][0], items[1][3][0], items[0][2][:160000]]
ref = [r.embed(fill(x)) for x in xs]          # the original model, before any change

def _freq_forward(self, x):
    # Same as the original, without torch.range (Core ML can't convert it): the
    # embedding row of each frequency bin, broadcast over batch and time.
    f = x.shape[2]
    return x + self.freq_embedder.weight[:f].transpose(0, 1).unsqueeze(0).unsqueeze(-1)
vendor.FreqEncoder.forward = _freq_forward
print("PyTorch efter bytet, likhet mot original:", [round(float(a @ r.embed(fill(x))), 5) for a, x in zip(ref, xs)])

class Full(torch.nn.Module):
    def __init__(s, enc): super().__init__(); s.enc = enc
    def forward(s, wav):
        e = s.enc(s.enc.spec_frontend(wav)).reshape(1, -1)
        return e / torch.linalg.norm(e)
m = Full(r.enc).eval()
ts = torch.jit.trace(m, torch.randn(1, 160000) * 0.1)
ml = ct.convert(ts, inputs=[ct.TensorType(name="waveform", shape=(1, 160000))],
                outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.macOS15,
                compute_precision=ct.precision.FLOAT16)
ml.save("ReDimNet2Plus.mlpackage")
for a, x in zip(ref, xs):
    t0 = time.time(); c = ml.predict({"waveform": fill(x)[None, :]})["embedding"].reshape(-1); dt = time.time() - t0
    print(f"{len(x)/16000:5.1f} s  likhet Core ML mot original {float(a @ (c / np.linalg.norm(c))):.4f}  tid {dt*1000:.0f} ms")
for cu in (ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY):
    m2 = ct.models.MLModel("ReDimNet2Plus.mlpackage", compute_units=cu); f = fill(xs[0])[None, :]
    m2.predict({"waveform": f}); t0 = time.time()
    for _ in range(5): m2.predict({"waveform": f})
    print(cu.name, round((time.time() - t0) / 5 * 1000), "ms per tiosekundersfönster")
