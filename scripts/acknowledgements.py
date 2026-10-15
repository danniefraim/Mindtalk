#!/usr/bin/env python3
"""Writes Mindtalk/Resources/Acknowledgements.txt — the licences that ship with the app.

FluidAudio is compiled into Mindtalk, so its licence (Apache 2.0) and the
third-party notices it carries (among them fastcluster, BSD) must travel with
the app. The speech models are downloaded by the user from Hugging Face and
are credited here too (CC BY 4.0). The voice model (ReDimNet2+) is included
in the app, so its licences are written out in full; so is the list of first
names (SCB, CC BY 4.0) the round of introductions uses.

Run after `make build` (it reads the resolved package checkout), and again
whenever FluidAudio is updated:  python3 scripts/acknowledgements.py
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def checkout(name):
    return next((p for p in (os.path.join(ROOT, "build", d, "checkouts", name)
                             for d in ("SourcePackages", "release/SourcePackages")) if os.path.isdir(p)),
                os.path.join(ROOT, "build", "SourcePackages", "checkouts", name))

FLUID = checkout("FluidAudio")
SPARKLE = checkout("Sparkle")
OUT = os.path.join(ROOT, "Mindtalk", "Resources", "Acknowledgements.txt")

if not (os.path.isdir(FLUID) and os.path.isdir(SPARKLE)):
    sys.exit("Package checkouts missing – run `make build` first.")

versions = dict(re.findall(r'\n  (\w+):\n    url: .*\n    exactVersion:\s*([\d.]+)', open(os.path.join(ROOT, "project.yml")).read()))
version = versions["FluidAudio"]
rule = "=" * 72

parts = [f"""Mindtalk – acknowledgements
{rule}

Mindtalk is made by Mindact Solutions AB. It is built on the work below,
used under the licences that follow.


SPEECH MODELS
{rule}

Mindtalk does not include any speech model. The one you choose is downloaded
to your Mac from Hugging Face, unmodified, from the repositories below.

Klang Pianissimo — by Klang AI AB
  https://huggingface.co/KlangAI/pianissimo-sv
  Core ML version by markstrom:
  https://huggingface.co/markstrom/pianissimo-sv-coreml
  Licence: Creative Commons Attribution 4.0 International (CC BY 4.0)

Parakeet Ultra — by Moondream
  https://huggingface.co/moondream/parakeet-ultra
  Core ML version by FluidInference:
  https://huggingface.co/FluidInference/parakeet-ultra-coreml
  Licence: Creative Commons Attribution 4.0 International (CC BY 4.0)

Both are built on NVIDIA Parakeet TDT 0.6B v3 — by NVIDIA
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  Licence: Creative Commons Attribution 4.0 International (CC BY 4.0)

CC BY 4.0: https://creativecommons.org/licenses/by/4.0/legalcode


WORD LIST AND MEETING MODELS
{rule}

Also downloaded to your Mac, unmodified, when you first use them:

Parakeet TDT-CTC 110M — by NVIDIA (the Ordlista listens once more with it)
  https://huggingface.co/nvidia/parakeet-tdt_ctc-110m
  Core ML version by FluidInference:
  https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml
  Licence: Creative Commons Attribution 4.0 International (CC BY 4.0)

Nemotron 3 Speaker Diarization — by NVIDIA (who speaks when, in meetings)
  Core ML version by FluidInference:
  https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
  Licence: OpenMDW License v1.1
  https://openmdw.ai/license/


NOTES MODEL (OPTIONAL)
{rule}

"Bättre anteckningar" downloads, only if you choose it, a model that writes
meeting notes on your Mac:

Gemma 4 26B-A4B (instruction-tuned) — by Google DeepMind
  https://huggingface.co/google/gemma-4-26B-A4B-it
  MLX 4-bit version by LM Studio:
  https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit
  Licence: Apache License, Version 2.0
  https://www.apache.org/licenses/LICENSE-2.0


FIRST NAMES (INCLUDED)
{rule}

The round of introductions ("Vem är här?") takes a name said on its own only
if it is one of the first names people in Sweden have — so a misheard sound
never becomes someone's name. The list (FirstNames.txt) is every first name
at least twenty people carried in 2020.

Source: Statistiska centralbyrån (Statistics Sweden, SCB),
  "Statistik över namn efter födelseland 2020",
  via Svensk nationell datatjänst: https://doi.org/10.5878/fc4h-rp11
  Licence: Creative Commons Attribution 4.0 International (CC BY 4.0)
  https://creativecommons.org/licenses/by/4.0/
  Reduced to the names alone (no counts) by Mindact Solutions AB.


VOICE MODEL (INCLUDED)
{rule}

"Känn igen röster" turns a voice into a voiceprint with this model. It is
included in Mindtalk and runs on your Mac; nothing is downloaded or sent.

ReDimNet2+ — by LAB260
  https://huggingface.co/lab260/redimnet2-plus
  Weights licence: Apache License, Version 2.0 (full text under FluidAudio below)
  Built on ReDimNet2 by Palabra.ai: https://github.com/PalabraAI/redimnet2
  Converted to Core ML and quantised to 8 bits by Mindact Solutions AB.

ReDimNet2+ code licence:

MIT License

Copyright (c) 2026 LAB260 

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

ReDimNet2 code licence:

MIT License

Copyright (c) 2026 Palabra.ai

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


FLUIDAUDIO {version}
{rule}

Runs the speech models on the Neural Engine. Included in Mindtalk.
https://github.com/FluidInference/FluidAudio
Licensed under the Apache License, Version 2.0:

""", open(os.path.join(FLUID, "LICENSE")).read().strip()]

for path in sorted(glob.glob(os.path.join(FLUID, "ThirdPartyLicenses", "*"))):
    name = os.path.splitext(os.path.basename(path))[0].replace("-LICENSE", "")
    parts.append(f"\n\n\nFLUIDAUDIO THIRD-PARTY NOTICE: {name}\n{rule}\n\n" + open(path).read().strip())

parts.append(f"""\n\n\nSPARKLE {versions["Sparkle"]}
{rule}

Keeps Mindtalk up to date. Included in Mindtalk.
https://sparkle-project.org

""" + open(os.path.join(SPARKLE, "LICENSE")).read().strip())

# Everything else compiled in for "Bättre anteckningar" (MLX and the tokenizer),
# with its licence, from the resolved packages. swift-syntax only builds macros.
import json
resolved = next(iter(glob.glob(os.path.join(ROOT, "Mindtalk.xcodeproj", "**", "Package.resolved"), recursive=True)), None)
pins = json.load(open(resolved))["pins"] if resolved else []
purpose = {"mlx-swift": "Runs the notes model on the Mac's GPU.",
           "mlx-swift-lm": "Loads and runs language models with MLX.",
           "swift-transformers": "Reads the notes model's tokenizer."}
for pin in sorted(pins, key=lambda p: p["identity"]):
    name = pin["identity"]
    if name in ("fluidaudio", "sparkle", "swift-syntax"):
        continue
    folder = next((d for d in glob.glob(os.path.join(os.path.dirname(FLUID), "*")) if os.path.basename(d).lower() == name), None)
    lic = next(iter(sorted(glob.glob(os.path.join(folder, "LICENSE*")))), None) if folder else None
    if not lic:
        sys.exit(f"No licence found for {name}")
    title = os.path.basename(folder)
    parts.append(f"\n\n\n{title.upper()} {pin['state'].get('version', '')}\n{rule}\n\n"
                 + (purpose.get(name, "Used by the components above.") + " Included in Mindtalk.\n")
                 + pin["location"] + "\n\n" + open(lic).read().strip())

text = "\n".join(parts) + "\n"
open(OUT, "w").write(text)
print(f"✓ {os.path.relpath(OUT, ROOT)} ({len(text) // 1024} KB, FluidAudio {version}, Sparkle {versions['Sparkle']})")
