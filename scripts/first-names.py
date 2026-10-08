#!/usr/bin/env python3
"""Builds Mindtalk/Resources/FirstNames.txt — the first names a word said on its
own in the round ("Anna") must be one of, so a misheard sound ("Nigg") never
becomes someone's name. ("Jag heter …" and "… här" take any name.)

Source: Statistics Sweden (SCB), "Statistik över namn efter födelseland 2020",
CC BY 4.0, via Svensk nationell datatjänst: https://doi.org/10.5878/fc4h-rp11
Every first name carried by at least MIN people in Sweden (men and women together).

  python3 scripts/first-names.py <folder with men_wide.csv and women_wide.csv>
"""
import csv, os, sys

MIN = 20
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Mindtalk", "Resources", "FirstNames.txt")

if len(sys.argv) != 2:
    sys.exit(__doc__)
counts = {}
for f in ("men_wide.csv", "women_wide.csv"):
    with open(os.path.join(sys.argv[1], f), newline="", encoding="utf-8") as fh:
        rows = csv.reader(fh)
        next(rows)
        for row in rows:
            if row[1].isdigit():
                counts[row[0]] = counts.get(row[0], 0) + int(row[1])
names = sorted(n for n, c in counts.items() if c >= MIN and any(ch.isalpha() for ch in n))
with open(OUT, "w", encoding="utf-8") as out:
    out.write("\n".join(names) + "\n")
print(f"{len(names)} förnamn (minst {MIN} bärare) → {os.path.relpath(OUT, ROOT)}")
