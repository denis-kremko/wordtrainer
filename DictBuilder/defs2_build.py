"""Simplicity pass candidate selection + frequency gate.

Flags definitions that (a) are synonym chains, (b) explain a common headword
with rarer words, or (c) sit in groups the first defs pass never validated.
Queue/batches use the defs_tools format, so its validate/apply are reused.

  build <db> <workdir> <patched_ids.json> <bound_ids.json> [leftover_queue.jsonl ...]
  gate <workdir> <db>       clean_verdicts.jsonl -> clean_final.jsonl (freq check)
"""
import json, os, re, sys
import sqlite3
from pathlib import Path

from dictfilters import stem_candidates

TOKEN_RE = re.compile(r"[A-Za-z']+")
BATCH_SENSES = 120
STOP = set("""the a an of to in on at by for with or and is are was were be been being it its as
from that this these those he she they them him his her their you your we our i me my us not no
but if so than then into onto one who which when where how what there here up out off over down
about such any all some etc has have had does do did can may will would should could must might
very more most much many few little own same other another each also just only even still yet
something someone anything anyone nothing usually often sometimes especially particularly""".split())

_ranks = None
def ranks():
    global _ranks
    if _ranks is None:
        r = {}
        for path, cap in (("/tmp/count_1w.txt", 100000), ("/tmp/en_full.txt", 250000)):
            for i, line in enumerate(open(path)):
                if i >= cap:
                    break
                w = line.split()[0].lower()
                if w not in r or i < r[w]:
                    r[w] = min(r.get(w, i), i)
        _ranks = r
    return _ranks

def best_rank(word):
    r = ranks()
    return min((r.get(s, 10**9) for s in stem_candidates(word)), default=10**9)

def content_tokens(text):
    out = []
    for w in TOKEN_RE.findall(text):
        w = w.lower().strip("'").removesuffix("'s").strip("'")
        if len(w) >= 3 and w not in STOP:
            out.append(w)
    return out

def exempt(text):
    """Capitalized mid-definition tokens (proper nouns, taxa) and the token
    right after one (binomial species names)."""
    out = set()
    tokens = TOKEN_RE.findall(text)
    for i, tok in enumerate(tokens):
        if i > 0 and tok[0].isupper():
            out.add(tok.lower())
            if i + 1 < len(tokens):
                out.add(tokens[i + 1].lower())
    return out

def head_rank(lemma):
    words = [w for w in TOKEN_RE.findall(lemma.lower()) if w not in STOP] or [lemma.lower()]
    return min(best_rank(w) for w in words)

def is_chain(definition):
    segments = [s for s in re.split(r"[;]", definition) if s.strip()]
    short = sum(1 for s in segments if len(content_tokens(s)) <= 2)
    total = content_tokens(definition)
    return short >= 2 or (len(total) <= 3 and len(definition.split()) <= 5)

# Plain A1-B1 phrasing is mostly stopwords; "thin" only means short raw text
# AND almost no content words.
def is_thin(definition):
    return len(content_tokens(definition)) < 4 and len(definition.split()) <= 7

def hard_words(definition, h_rank, threshold, factor=1.5):
    ex = exempt(definition)
    bad = []
    for w in set(content_tokens(definition)):
        # Contractions and quoted fragments miss the frequency lists entirely;
        # they are never the hard vocabulary this gate hunts.
        if w in ex or "'" in w:
            continue
        r = best_rank(w)
        if r > threshold and r > h_rank * factor:
            bad.append((w, r))
    return bad

# The hard-word flag only where it really hurts: a single, common headword
# whose short definition leans on rarer words than itself.
def hard_flag(lemma, definition, h_rank):
    if " " in lemma or h_rank > 10000:
        return False
    tokens = content_tokens(definition)
    if len(tokens) > 12:
        return False
    bad = hard_words(definition, h_rank, threshold=max(15000, 2 * h_rank))
    return len(bad) >= 2 or (len(bad) == 1 and len(tokens) <= 6)

def cmd_build(db_path, workdir, patched_path, bound_path, leftover_paths):
    patched = set(json.load(open(patched_path)))
    bound = set()
    for per in json.load(open(bound_path)).values():
        bound.update(per.values())

    leftover_groups = set()
    for lp in leftover_paths:
        for line in open(lp):
            leftover_groups.add(json.loads(line)["id"])

    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT id, lemma, pos, definition, example FROM entries ORDER BY lemma, pos, rank, id"
    ).fetchall()

    flagged_groups = {}   # gid -> reason set
    groups = {}           # gid -> [senses]
    stats = {"chain": 0, "hard": 0, "leftover": 0}
    for eid, lemma, pos, definition, example in rows:
        gid = f"{lemma}|{pos}"
        sense = {"i": eid, "d": definition, "e": example}
        if eid in patched:
            sense["p"] = 2
        elif eid in bound:
            sense["p"] = 1
        groups.setdefault(gid, []).append(sense)

        reasons = flagged_groups.setdefault(gid, set())
        if eid not in patched:
            h = head_rank(lemma)
            if h <= 30000 and is_chain(definition):
                reasons.add("chain")
            if hard_flag(lemma, definition, h):
                reasons.add("hard")
        if gid in leftover_groups:
            reasons.add("leftover")

    selected = [gid for gid, r in flagged_groups.items() if r]
    for gid in selected:
        for reason in flagged_groups[gid]:
            stats[reason] += 1

    os.makedirs(workdir, exist_ok=True)
    with open(f"{workdir}/queue.jsonl", "w") as f:
        for gid in selected:
            f.write(json.dumps({"id": gid, "s": groups[gid]}, ensure_ascii=False) + "\n")

    batch, senses, n = [], 0, 0
    for gid in selected:
        batch.append({"id": gid, "s": groups[gid]})
        senses += len(groups[gid])
        if senses >= BATCH_SENSES:
            n += 1
            json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
            batch, senses = [], 0
    if batch:
        n += 1
        json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)

    total_senses = sum(len(groups[g]) for g in selected)
    print(json.dumps({"groups": len(selected), "senses": total_senses,
                      "batches": n, "reasons": stats}))

def cmd_gate(workdir, db_path):
    wd = Path(workdir)
    heads = {}
    clean, rejected = [], []
    counts = {"freq_reject": 0, "chain_reject": 0, "thin_reject": 0}
    for line in open(wd / "clean_verdicts.jsonl"):
        verdict = json.loads(line)
        lemma = verdict["id"].rsplit("|", 1)[0]
        if lemma not in heads:
            heads[lemma] = head_rank(lemma)
        ok = True
        for v in verdict["v"]:
            if v["a"] != "rw":
                continue
            if is_chain(v["d"]):
                counts["chain_reject"] += 1
                ok = False
                break
            if is_thin(v["d"]):
                counts["thin_reject"] += 1
                ok = False
                break
            if hard_words(v["d"], heads[lemma], threshold=10000):
                counts["freq_reject"] += 1
                ok = False
                break
        (clean if ok else rejected).append(verdict)
    with open(wd / "clean_final.jsonl", "w") as f:
        for c in clean:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    with open(wd / "gate_rejects.jsonl", "w") as f:
        for r in rejected:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(json.dumps({"clean": len(clean), "rejected": len(rejected), **counts}))

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build":
        cmd_build(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:])
    elif cmd == "gate":
        cmd_gate(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
