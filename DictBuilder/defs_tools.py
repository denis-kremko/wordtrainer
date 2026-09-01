"""Definition-quality pass: rewrite synonym-chain definitions into simple
explanations and delete redundant sibling senses.

Queue rows are (lemma, pos) groups: {"id": "lemma|pos", "s": [{"i", "d", "e",
"p"?}]} where p=1 forbids deletion (a ready list binds to it) and p=2 locks the
sense entirely (hand-patched). Verdicts, one line per group, same order:
{"id": ..., "v": [{"i", "a": "keep"} | {"i", "a": "rw", "d": ...} | {"i", "a": "del"}]}

Commands:
  build <db> <workdir> <patched_ids.json> <bound_ids.json>   queue + batches
  validate <workdir>                                          clean/requeue jsonl
  apply <workdir>/clean_verdicts.jsonl <db>                   UPDATE + DELETE
"""
import json, os, re, sqlite3, sys
from pathlib import Path

from dictfilters import content_words, stem_candidates

BATCH_SENSES = 160


def root_echo(lemma: str, text: str) -> bool:
    lemma_words = content_words(lemma) or [w for w in re.findall(r"[a-z']+", lemma.lower())]
    stems = set()
    for w in lemma_words:
        stems.update(stem_candidates(w))
    for token in re.findall(r"[a-z']+", text.lower()):
        for stem in stem_candidates(token):
            if stem in stems:
                return True
    return False


def cmd_build(db_path, workdir, patched_path, bound_path):
    patched = set(json.load(open(patched_path)))
    bound = set()
    for per in json.load(open(bound_path)).values():
        bound.update(per.values())
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT id, lemma, pos, definition, example FROM entries ORDER BY lemma, pos, rank, id"
    ).fetchall()
    groups = []
    current_key, current = None, None
    for eid, lemma, pos, definition, example in rows:
        key = f"{lemma}|{pos}"
        if key != current_key:
            current = {"id": key, "s": []}
            groups.append(current)
            current_key = key
        sense = {"i": eid, "d": definition, "e": example}
        if eid in patched:
            sense["p"] = 2
        elif eid in bound:
            sense["p"] = 1
        current["s"].append(sense)

    os.makedirs(workdir, exist_ok=True)
    with open(f"{workdir}/queue.jsonl", "w") as f:
        for g in groups:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")

    batch, senses, n = [], 0, 0
    for g in groups:
        batch.append(g)
        senses += len(g["s"])
        if senses >= BATCH_SENSES:
            n += 1
            json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
            batch, senses = [], 0
    if batch:
        n += 1
        json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
    print(json.dumps({"groups": len(groups), "batches": n,
                      "protected_locked": len(patched), "protected_no_delete": len(bound)}))


def load_queue(workdir):
    groups = {}
    for line in open(f"{workdir}/queue.jsonl"):
        g = json.loads(line)
        groups[g["id"]] = g
    return groups


def cmd_validate(workdir):
    groups = load_queue(workdir)
    wd = Path(workdir)
    verdicts = {}
    stats = {"bad_lines": 0}
    for f in sorted(wd.glob("verdict_*.jsonl")):
        for line in open(f):
            line = line.strip()
            if not line:
                continue
            try:
                v = json.loads(line)
                verdicts[v["id"]] = v["v"]
            except Exception:
                stats["bad_lines"] += 1

    clean, requeue = [], []
    counts = {"kept": 0, "rewritten": 0, "deleted": 0}
    for gid, group in groups.items():
        verdict = verdicts.get(gid)
        senses = {s["i"]: s for s in group["s"]}
        lemma = gid.rsplit("|", 1)[0]

        def bad(reason):
            requeue.append(group)
            stats[reason] = stats.get(reason, 0) + 1

        if verdict is None:
            bad("missing")
            continue
        seen_ids = [v.get("i") for v in verdict]
        if sorted(seen_ids) != sorted(senses):
            bad("id_mismatch")
            continue
        survivors = 0
        ok = True
        for v in verdict:
            sense = senses[v["i"]]
            action = v.get("a")
            if sense.get("p") == 2 and action != "keep":
                ok, _ = False, bad("locked_touched")
                break
            if action == "keep":
                survivors += 1
            elif action == "del":
                if sense.get("p"):
                    ok, _ = False, bad("protected_deleted")
                    break
            elif action == "rw":
                d = (v.get("d") or "").strip()
                if not (20 <= len(d) <= 240):
                    ok, _ = False, bad("rw_length")
                    break
                if d.startswith("(") or d.lower().startswith("alternative form"):
                    ok, _ = False, bad("rw_format")
                    break
                if root_echo(lemma, d):
                    ok, _ = False, bad("rw_root_echo")
                    break
                survivors += 1
            else:
                ok, _ = False, bad("bad_action")
                break
        if not ok:
            continue
        if survivors == 0:
            bad("no_survivor")
            continue
        for v in verdict:
            if v["a"] == "keep":
                counts["kept"] += 1
            elif v["a"] == "rw":
                counts["rewritten"] += 1
            else:
                counts["deleted"] += 1
        clean.append({"id": gid, "v": verdict})

    with open(wd / "clean_verdicts.jsonl", "w") as f:
        for c in clean:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    with open(wd / "requeue.jsonl", "w") as f:
        for g in requeue:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    stats.update(counts)
    print(json.dumps(stats, indent=1))
    print(f"clean groups: {len(clean)}, requeue: {len(requeue)}")


def normalize_rewrite(text):
    text = text.strip()
    if text and text[0].islower():
        text = text[0].upper() + text[1:]
    if text and text[-1].isalnum():
        text += "."
    return text


def cmd_apply(clean_path, db_path):
    conn = sqlite3.connect(db_path)
    rewrites, deletes = 0, 0
    missing = 0
    for line in open(clean_path):
        verdict = json.loads(line)
        for v in verdict["v"]:
            if v["a"] == "rw":
                n = conn.execute("UPDATE entries SET definition = ? WHERE id = ?",
                                 (normalize_rewrite(v["d"]), v["i"])).rowcount
                rewrites += n
                missing += 1 - n
            elif v["a"] == "del":
                n = conn.execute("DELETE FROM entries WHERE id = ?", (v["i"],)).rowcount
                deletes += n
                missing += 1 - n
    conn.commit()
    print(json.dumps({"rewrites": rewrites, "deletes": deletes, "missing_ids": missing}))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build":
        cmd_build(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "validate":
        cmd_validate(sys.argv[2])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        sys.exit("unknown command")
