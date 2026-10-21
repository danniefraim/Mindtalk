#!/usr/bin/env python3
"""Synthetic name rounds for `scripts/round-replay.sh`, and the scoring of a replay.

  round-fixtures.py make OUTDIR          the fixtures: OUTDIR/<name>.wav + <name>.json
  round-fixtures.py score FIXTURE.json RESULT.txt [--label RUN] [--truth MEETING.json
                                          [--want JSON] [--background 0,2] [--optional 1]]
                                          one line: what each voice should be called and
                                          what the replay called it (a real meeting: by
                                          the voices and names it was saved with, or
                                          --want, with --background voices to stay unnamed)

People around a table are macOS voices (`say`) reading Swedish: each says "Hej, jag
heter X, och …" on their turn of the round, then the meeting goes on with a sentence
or two each, some starting before the last one ended. They sit at different distances
(levels), one is on a speakerphone (band-limited, quieter), and some fixtures have a
voice talking through everything (a radio, the next table). Standard library only.
"""
import array, hashlib, json, math, os, random, re, subprocess, sys, wave

SR = 16000
# (say voice, name, seat). Only Alva speaks Swedish natively; the others read it with
# an accent, which the speech model still hears as "jag heter …". Clean synthetic
# voices all sound alike to the voice model (it heard six of them as one or two), so
# each sits in its own place: a voice a little deeper or brighter, nearer a wall, in an
# echoing corner — then it tells all six apart (measured: six voices, six speakers).
PEOPLE = [
    ("Alva", "Anna", "plain"),
    ("Eddy (Tyska (Tyskland))", "Erik", "deep"),
    ("Nora", "Karin", "bright"),
    ("Grandpa (Tyska (Tyskland))", "Johan", "hall"),
    ("Sara", "Maria", "dark"),
    ("Reed (Finska (Finland))", "Lars", "small"),
]
BACKGROUND = ("Rocko (Tyska (Tyskland))", "radio")
TOPICS = ["ekonomin", "försäljningen", "designen", "kundtjänsten", "utvecklingen", "inköpen"]
TALK = [
    "Jag tycker att vi ska börja med budgeten för nästa kvartal.",
    "Det låter bra, men vi behöver också titta på leveranstiderna.",
    "Kunderna har frågat mycket om den nya tjänsten den senaste veckan.",
    "Vi kan ta fram ett förslag till mötet på torsdag.",
    "Jag håller med, och jag kan skicka siffrorna i eftermiddag.",
    "Vi borde testa det med några användare innan vi bestämmer oss.",
    "Det viktigaste är att vi blir klara före sommaren.",
    "Jag har pratat med leverantören och de kan leverera i maj.",
    "Kan vi sätta upp ett uppföljningsmöte om två veckor?",
    "Jag skriver ihop en sammanfattning och delar den med alla.",
    "Den nya versionen fungerar bättre än den gamla.",
    "Vi behöver bli tydligare med vem som gör vad.",
]
ENROL = [
    "Jag har jobbat här i fem år och trivs väldigt bra med kollegorna.",
    "På fritiden tycker jag om att laga mat och gå långa promenader i skogen.",
    "I dag vill jag mest lyssna och lära mig hur ni brukar arbeta.",
    "Förra året var vi på en konferens i Göteborg och det var mycket givande.",
]
WEATHER = ("Under morgonen drar ett regnområde in över de västra delarna av landet. Det blir blåsigt "
           "längs kusterna och temperaturen ligger runt tio grader. Under eftermiddagen klarnar det upp "
           "i öster, men i norr fortsätter det att snöa på fjällen. I morgon väntas ett nytt lågtryck med "
           "kraftig vind och mer regn i söder. Mot helgen blir det lugnare väder med sol och några moln, "
           "men nätterna blir kalla och det kan bli frost i inlandet. ")

def rendered(cache, voice, text):
    """16 kHz mono samples (floats) of a voice saying a text, cached by both."""
    key = hashlib.sha1((voice + "|" + text).encode()).hexdigest()[:16]
    wav = os.path.join(cache, key + ".wav")
    if not os.path.exists(wav):
        aiff = os.path.join(cache, key + ".aiff")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
        os.remove(aiff)
    with wave.open(wav) as w:
        a = array.array("h", w.readframes(w.getnframes()))
    return [x / 32768.0 for x in a]

def resample(x, f):
    """Played at another speed: f < 1 slower and deeper, f > 1 quicker and brighter."""
    out, n = [], int(len(x) / f)
    for i in range(n):
        p = i * f; k = int(p); a = p - k
        if k + 1 >= len(x): break
        out.append(x[k] * (1 - a) + x[k + 1] * a)
    return out

def lowpass(x, fc):
    a, y, out = math.exp(-2 * math.pi * fc / SR), 0.0, []
    for s in x:
        y = (1 - a) * s + a * y; out.append(y)
    return out

def highpass(x, fc):
    a, y, prev, out = math.exp(-2 * math.pi * fc / SR), 0.0, 0.0, []
    for s in x:
        y = a * (y + s - prev); prev = s; out.append(y)
    return out

def room(x, delays_ms, g):
    """Echoes off the walls: a few delayed, fading copies."""
    out = list(x) + [0.0] * int(SR * 0.3)
    for d in delays_ms:
        k = int(SR * d / 1000)
        for i, s in enumerate(x): out[i + k] += s * g
        g *= 0.7
    return out

SEATS = {
    "plain": lambda x: x,
    "deep": lambda x: room(lowpass(resample(x, 0.84), 2800), [19, 31, 47], 0.35),
    "bright": lambda x: highpass(resample(x, 1.12), 350),
    "hall": lambda x: room(x, [41, 67, 89, 113], 0.4),
    "dark": lambda x: lowpass(resample(x, 0.92), 2000),
    "small": lambda x: room(highpass(resample(x, 1.2), 250), [7, 13], 0.5),
    "radio": lambda x: room(lowpass(highpass(resample(x, 0.9), 300), 3000), [29, 53, 71], 0.45),
}

def phone(x):
    """A speakerphone: 300–3400 Hz (two one-pole filters) and a little quieter."""
    out, lo, hp, prev = [], 0.0, 0.0, 0.0
    a_lo = math.exp(-2 * math.pi * 3400 / SR)
    a_hi = math.exp(-2 * math.pi * 300 / SR)
    for s in x:
        lo = (1 - a_lo) * s + a_lo * lo
        hp = a_hi * (hp + lo - prev)
        prev = lo
        out.append(hp * 1.6)
    return out

def build(cache, name, n, background=None, overlap=True, enrol=False, phone_seat=None, seed=1):
    """One fixture: the round, then the meeting. Returns (samples, description)."""
    rng = random.Random(seed)
    gains = [1.0, 0.6, 0.8, 0.45, 0.7, 0.5][:n]
    people = PEOPLE[:n]
    segments, t = [], 1.5
    clips = []
    seat = lambda k, x: phone(x) if phone_seat == k else SEATS[people[k][2]](x)
    # The round: one at a time, a pause for the next turn to begin after each name.
    for k, (voice, person, _) in enumerate(people):
        text = f"Hej, jag heter {person}, och jag jobbar med {TOPICS[k]}."
        if enrol:
            text = f"Hej, jag heter {person}. " + ENROL[k % len(ENROL)]
        x = seat(k, rendered(cache, voice, text))
        clips.append((t, x, gains[k]))
        segments.append({"who": k, "name": person, "start": t, "end": t + len(x) / SR, "kind": "intro"})
        t += len(x) / SR + 3.2
    round_end = t + 1.0
    t += 2.5
    # The meeting: a sentence or two each, in a shuffled order, some cutting in.
    order = [k for k in range(n) for _ in range(2)]
    rng.shuffle(order)
    for i, k in enumerate(order):
        voice, person, _ = people[k]
        line = (ENROL if enrol else TALK)[(i * 5 + k) % len(ENROL if enrol else TALK)]
        x = seat(k, rendered(cache, voice, line))
        if overlap and i % 3 == 2 and segments[-1]["kind"] == "talk":
            t -= 0.4                                   # starts before the last one ended
        clips.append((t, x, gains[k]))
        segments.append({"who": k, "name": person, "start": t, "end": t + len(x) / SR, "kind": "talk"})
        t += len(x) / SR + 0.6
    total = t + 2.0
    buf = [0.0] * int(total * SR)
    if background is not None:
        # A radio in the corner: sentence after sentence, a short breath between them.
        start = 0.2
        sentences = [x.strip() + "." for x in WEATHER.split(".") if x.strip()]
        k = 0
        while start < total:
            x = SEATS[BACKGROUND[1]](rendered(cache, BACKGROUND[0], sentences[k % len(sentences)]))
            end = min(total, start + len(x) / SR)
            clips.append((start, x[: int((end - start) * SR)], background))
            segments.append({"who": -1, "name": "", "start": start, "end": end, "kind": "background"})
            start = end + 0.6
            k += 1
    for start, x, g in clips:
        o = int(start * SR)
        for i, s in enumerate(x):
            if o + i < len(buf): buf[o + i] += s * g
    peak = max(1e-9, max(abs(s) for s in buf))
    scale = min(1.0, 0.95 / peak)
    return buf, scale, {"fixture": name, "people": [p for _, p, _ in people], "segments": segments,
                        "end_round_at": round(round_end, 1), "background": background is not None}

FIXTURES = [
    # name, people, background gain, extra
    ("quiet-2", 2, None, {}),
    ("quiet-4", 4, None, {"phone_seat": 3}),
    ("quiet-6", 6, None, {}),
    ("bg-2", 2, 0.15, {}),
    ("bg-4", 4, 0.15, {"phone_seat": 3}),
    ("bg-6", 6, 0.15, {}),
    ("loudbg-2", 2, 0.5, {}),
    ("enrol-6", 6, None, {"enrol": True, "overlap": False}),
]

def make(out):
    cache = os.path.join(out, ".cache")
    os.makedirs(cache, exist_ok=True)
    for name, n, bg, extra in FIXTURES:
        buf, scale, desc = build(cache, name, n, background=bg, **extra)
        pcm = array.array("h", (max(-32767, min(32767, int(s * scale * 32767))) for s in buf))
        with wave.open(os.path.join(out, name + ".wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
        json.dump(desc, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False, indent=1)
        print(f"{name}: {len(buf) / SR:.0f} s, {n} personer, bakgrund {bg}, rundan slut {desc['end_round_at']} s")

def sound(name):
    """A first name as it sounds: Mathias and Mattias, Eric and Erik are one name."""
    s = (name or "").split(" ")[0].lower()
    for a, b in (("th", "t"), ("ph", "f"), ("ck", "k"), ("c", "k"), ("z", "s"), ("w", "v")):
        s = s.replace(a, b)
    out = ""
    for ch in s:
        if ch.isalpha() and ch != out[-1:]: out += ch
    return out

def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))

def score(fixture, result_txt, truth=None, want=None, background_voices=(), run_label=None, optional_voices=()):
    """Who each voice in the replay is (by time), what it should be called, what it got."""
    line = next((l for l in open(result_txt, errors="replace") if l.startswith("ROUND-RESULT ")), None)
    if line is None:
        return {"fixture": fixture, "error": "no ROUND-RESULT"}
    res = json.loads(line[len("ROUND-RESULT "):])
    # The speech model stretches a last word over the quiet after it: a second at most.
    words = [[w[0], min(w[1], w[0] + 1.0), w[2], w[3]] for w in res["words"]]
    names = {int(k): v for k, v in res["names"].items() if v}
    if truth:
        # A real meeting: the voices and names it ended with when it was recorded.
        r = json.load(open(truth))
        segs = [{"who": w.get("speaker"), "start": w["start"], "end": w["end"]} for w in r["words"]
                if w.get("speaker") is not None and w["speaker"] >= 0]
        expected_name = {int(k): v for k, v in (want or r["names"]).items() if v}
        # Recognised by voice when it was recorded (never said in the round): a replay
        # without your voices can't know them — named or not, both are right.
        optional = set(optional_voices) if want else {int(k) for k in r.get("recognized", {})}
        label = os.path.basename(os.path.dirname(truth))[:8]
        background = set(background_voices)
    else:
        d = json.load(open(fixture))
        segs = d["segments"]
        label = d["fixture"]
        # The name each person said, as the round heard it: the turn held while they
        # introduced themselves. A person the round never took a turn for (it heard them
        # as someone already there) can't be named by the placement: either is right.
        turns = res.get("turns", [])
        expected_name, optional = {}, set()
        for k, p in enumerate(d["people"]):
            intro = next(g for g in segs if g["who"] == k and g["kind"] == "intro")
            mine = [t for t in turns if overlap(t["from"], t["to"], intro["start"] - 0.5, intro["end"] + 0.5) > 0]
            expected_name[k] = mine[0]["name"] if mine else p
            if not mine: optional.add(k)
        background = {-1}
    # Each replay voice: the person (or background) its words were said by. A word said
    # while someone at the table spoke is theirs (the background runs under everything).
    who = {}
    for s in {w[2] for w in words if w[2] >= 0}:
        acc = {}
        for w in words:
            if w[2] != s: continue
            by = {}
            for g in segs:
                o = overlap(w[0], w[1], g["start"], g["end"])
                if o > 0: by[g["who"]] = by.get(g["who"], 0) + o
            people = {k: v for k, v in by.items() if k not in background}
            for k, v in (people or by).items(): acc[k] = acc.get(k, 0) + v
        if acc: who[s] = max(acc, key=acc.get)
    rows, ok = [], True
    for s in sorted(who):
        person = who[s]
        want = "" if person in background else expected_name.get(person, "")
        got = names.get(s, "")
        good = (sound(got) == sound(want) or (person in optional and not got)) if want else got == ""
        # A person heard as two voices: one of them named is enough.
        rows.append({"voice": s, "is": "bakgrund" if person in background
                     else expected_name.get(person, f"?{person}") + ("*" if person in optional else ""),
                     "want": want, "got": got, "ok": good})
    # Each person named on (one of) their voices; nobody else named; the background never.
    for person, want in expected_name.items():
        if not want or person in optional: continue
        mine = [r for r in rows if who.get(r["voice"]) == person]
        if mine and not any(sound(r["got"]) == sound(want) for r in mine): ok = False
    for r in rows:
        if r["got"] and not r["ok"] and not any(x["got"] == r["got"] and x["ok"] for x in rows):
            ok = False
        if r["is"] == "bakgrund" and r["got"]: ok = False
    if run_label: label = run_label
    return {"fixture": label, "voices": rows, "names": names, "pass": ok}

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "make":
        make(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "score":
        opt = lambda f: sys.argv[sys.argv.index(f) + 1] if f in sys.argv else None
        want = json.loads(opt("--want")) if opt("--want") else None
        bg = [int(x) for x in opt("--background").split(",")] if opt("--background") else []
        optional = [int(x) for x in opt("--optional").split(",")] if opt("--optional") else []
        print(json.dumps(score(sys.argv[2], sys.argv[3], opt("--truth"), want, bg, opt("--label"), optional), ensure_ascii=False))
    else:
        print(__doc__); sys.exit(2)
