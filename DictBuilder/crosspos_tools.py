"""Cross-POS pass: one global importance order per lemma across all its parts
of speech, deleting parasitic senses that only restate another POS.

Queue rows: {"id": lemma, "s": [{"i", "p" (pos), "d", "e"?, "prot"?}]}
Verdicts:   {"id": lemma, "o": [ids most-important-first], "x": [deleted ids]}

  build <db> <workdir> <patched_ids.json> <bound_ids.json>
  validate <workdir>
  apply <workdir>/clean_rank.jsonl <db>
"""
import json, os, sqlite3, sys
from collections import defaultdict
from pathlib import Path

BATCH_LEMMAS = 40


def cmd_build(db_path, workdir, patched_path, bound_path):
    protected = set(json.load(open(patched_path)))
    for per in json.load(open(bound_path)).values():
        protected.update(per.values())
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT id, lemma, pos, definition, example FROM entries WHERE lemma IN ("
        " SELECT lemma FROM entries GROUP BY lemma HAVING COUNT(DISTINCT pos) > 1)"
        " ORDER BY lemma, pos, rank, id").fetchall()
    groups = defaultdict(list)
    for eid, lemma, pos, definition, example in rows:
        sense = {"i": eid, "p": pos, "d": definition}
        if example:
            sense["e"] = example[:100]
        if eid in protected:
            sense["prot"] = 1
        groups[lemma].append(sense)

    os.makedirs(workdir, exist_ok=True)
    with open(f"{workdir}/queue.jsonl", "w") as f:
        for lemma, senses in groups.items():
            f.write(json.dumps({"id": lemma, "s": senses}, ensure_ascii=False) + "\n")

    batch, n = [], 0
    for lemma, senses in groups.items():
        batch.append({"id": lemma, "s": senses})
        if len(batch) >= BATCH_LEMMAS:
            n += 1
            json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
            batch = []
    if batch:
        n += 1
        json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
    print(json.dumps({"lemmas": len(groups),
                      "senses": sum(len(s) for s in groups.values()),
                      "batches": n, "protected_in_scope": len(protected)}))


def cmd_validate(workdir):
    wd = Path(workdir)
    queue = {}
    for line in open(wd / "queue.jsonl"):
        g = json.loads(line)
        queue[g["id"]] = g

    verdicts = {}
    stats = defaultdict(int)
    for vf in sorted(wd.glob("verdict_*.jsonl")):
        for line in open(vf):
            line = line.strip()
            if not line:
                continue
            try:
                v = json.loads(line)
                verdicts[v["id"]] = v
            except Exception:
                stats["bad_lines"] += 1

    clean, requeue = [], []
    for gid, row in queue.items():
        ids = {s["i"] for s in row["s"]}
        prot = {s["i"] for s in row["s"] if s.get("prot")}
        v = verdicts.get(gid)
        if v is None:
            stats["missing"] += 1
            requeue.append(row)
            continue
        o, x = v.get("o"), v.get("x", [])
        if (not isinstance(o, list) or not isinstance(x, list) or not o
                or set(o) | set(x) != ids or set(o) & set(x)
                or len(o) + len(x) != len(ids)):
            stats["bad_partition"] += 1
            requeue.append(row)
            continue
        if prot & set(x):
            stats["protected_deleted"] += 1
            requeue.append(row)
            continue
        stats["ok"] += 1
        stats["deleted"] += len(x)
        clean.append({"id": gid, "o": o, "x": x})

    with open(wd / "clean_rank.jsonl", "w") as f:
        for c in clean:
            f.write(json.dumps(c) + "\n")
    with open(wd / "requeue.jsonl", "w") as f:
        for g in requeue:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    print(json.dumps(dict(stats), indent=1))
    print(f"clean: {len(clean)}, requeue: {len(requeue)}")


def cmd_apply(clean_path, db_path):
    conn = sqlite3.connect(db_path)
    ranks, drops = [], []
    for line in open(clean_path):
        v = json.loads(line)
        for rank, id_ in enumerate(v["o"]):
            ranks.append((rank, id_))
        for id_ in v["x"]:
            drops.append((id_,))
    conn.executemany("UPDATE entries SET rank = ? WHERE id = ?", ranks)
    conn.executemany("DELETE FROM entries WHERE id = ?", drops)
    conn.commit()
    conn.execute("DELETE FROM forms WHERE lemma NOT IN (SELECT DISTINCT lemma FROM entries)")
    conn.commit()
    conn.close()
    print(f"applied: {len(ranks)} ranks, {len(drops)} deletions")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "build":
        cmd_build(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "validate":
        cmd_validate(sys.argv[2])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
