import re, json, collections
from systems import SYSTEMS
BAD = re.compile(r"\((?:[^)]*\b(?:Redux|Translated|Pirate|Bootleg|Beta|Proto|Prototype|Demo|Sample|Unl|Pirate|Kiosk|Hack|Aftermarket|Homebrew|Program|Test|BIOS|Debug|Tech Demo|Promo|Competition|Trade|Preview|Unknown|Enhancement Chip|Batteryless|Reprint Unl)\b[^)]*)\)|\[BIOS\]", re.I)
REGION_RANK = [("Norway",0),("Scandinavia",0),("Sweden",1),("Denmark",1),("Finland",1),("Europe",2),("World",3),("UK",4),("Germany",5),("France",5),("USA",6),("Australia",7),("Japan",9)]
def region_of(name):
    m = re.search(r"\(([^)]*)\)", name)
    tags = m.group(1) if m else ""
    best, label = 50, tags.split(",")[0].strip() if tags else ""
    for r, rank in REGION_RANK:
        if r in tags and rank < best: best, label = rank, r
    return best, label
def clean(name):
    t = re.sub(r"\s*[\(\[][^)\]]*[\)\]]", "", name).strip()
    t = re.sub(r"\s+(Rev\s*\S+|v\d+(\.\d+)*)$", "", t, flags=re.I).strip()
    # "Legend of Zelda, The - A Link..." -> "The Legend of Zelda - A Link..."
    t = re.sub(r"^(.*?), (The|A|An|Die|Der|Das|Le|La|Les)(\b.*)$", lambda m: f"{m.group(2)} {m.group(1)}{m.group(3)}", t, count=1)
    return re.sub(r"\s{2,}", " ", t).strip()
out, stats = [], {}
for folder, name, short in SYSTEMS:
    key = short.replace(" ", "_"); repo = name.replace(" ", "_")
    files = [l for l in open(f"box_{key}.txt").read().splitlines() if l]
    best = {}
    for f in files:
        if BAD.search(f): continue
        title = clean(f)
        if len(title) < 2 or re.search(r"\bRedux\b", title, re.I): continue
        rank, region = region_of(f)
        if rank >= 50: continue  # no real region (fan-made, pirate, dated hacks) -> skip
        k = title.lower()
        cur = best.get(k)
        # prefer better region; then prefer names without Rev/Disc noise (shorter)
        if cur is None or (rank, len(f)) < (cur[0], len(cur[2])):
            best[k] = (rank, region, f, title)
    for rank, region, f, title in best.values():
        out.append({"s": short, "t": title, "r": region, "f": f, "p": repo})
    stats[short] = len(best)
for k, v in stats.items(): print(f"{k:14} {v:6}")
print("TOTAL", len(out))
json.dump(out, open("games_all.json", "w"), ensure_ascii=False, separators=(",", ":"))
import os; print("json MB", round(os.path.getsize("games_all.json")/1e6, 2))
# spot checks
for q in ["zelda", "pokemon", "mario kart", "tony hawk", "final fantasy vii", "gran turismo"]:
    hits = [f"{g['t']} [{g['s']}, {g['r']}]" for g in out if q in g['t'].lower()][:6]
    print(q, "->", hits)
