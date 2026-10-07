# Voice-model comparison

Compares speaker-embedding models on your own meetings (named speakers only, read
from `~/Library/Application Support/Mindtalk/Meetings`). Nothing leaves the Mac.

Setup (Python 3.12; coremltools 9 needs `numpy<2.3`):

    uv venv -p python3.12 .venv
    uv pip install -p .venv/bin/python "torch==2.7.0" "torchaudio==2.7.0" "numpy<2.3" \
        soundfile coremltools omegaconf hydra-core huggingface_hub scipy
    git clone --depth 1 https://github.com/lab260ru/redimnet2-plus.git
    # pyannote Core ML models and ReDimNet2+ weights:
    .venv/bin/python -c "from huggingface_hub import snapshot_download as s, hf_hub_download as h; \
      s('FluidInference/speaker-diarization-coreml', allow_patterns=['FBank.mlmodelc/*','Embedding.mlmodelc/*'], local_dir='pyannote'); \
      h('lab260/redimnet2-plus','pytorch_model_fsdp.bin', local_dir='redimnet')"
    .venv/bin/python convert.py      # ReDimNet2+ → ReDimNet2Plus.mlpackage (checks it against PyTorch)
    .venv/bin/python bench.py

`SKIP="meeting:name:clip,…"` leaves out clips known to be mislabelled by diarization.

Notes from the first run (October 2026):
- ReDimNet2+ needs `return_2d_output: True` (the model card says False) and F = 72.
- Its frequency encoder uses `torch.range`, which Core ML can't convert; `convert.py`
  swaps in an equivalent (verified identical).
- The converted model is wrong on the Neural Engine (CPU_AND_NE); CPU, GPU and ALL
  match PyTorch to 0.9996+. Run it on the CPU.
- pyannote's embedding model works on 10 s windows; fill short speech by repeating it,
  not with silence (zero padding skews its features).
