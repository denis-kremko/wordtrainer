"""Queue + validate + apply for the translation-accuracy review swarm.

Groups are lemmas that have at least one translated sense; every sense of the
lemma is included for context, translated ones carry "t". Verdicts cover
exactly the translated ids: keep / {"a":"rw","t":"..."} / del.

  build <db> <workdir>
  validate <workdir>          -> clean_verdicts.jsonl + requeue.jsonl
  apply <workdir>/clean_verdicts.jsonl <db>
"""
import json, os, sys
import sqlite3
from pathlib import Path

from dictfilters import put_translation

BATCH_TRANSLATED = 100


def cmd_build(db_path, workdir):
    conn = sqlite3.connect(db_path)
    rows = conn.execute("""
        SELECT e.id, e.lemma, e.pos, e.definition, t.word
        FROM entries e LEFT JOIN translations t ON t.id = e.id
        WHERE e.lemma IN (SELECT DISTINCT e2.lemma FROM entries e2
                          JOIN translations t2 ON t2.id = e2.id)
        ORDER BY e.lemma, e.rank, e.id
    """).fetchall()
    groups = {}
    for eid, lemma, pos, definition, ru in rows:
        sense = {"i": eid, "p": pos, "d": definition}
        if ru:
            sense["t"] = ru
        groups.setdefault(lemma, []).append(sense)

    os.makedirs(workdir, exist_ok=True)
    with open(f"{workdir}/queue.jsonl", "w") as f:
        for lemma, senses in groups.items():
            f.write(json.dumps({"id": lemma, "s": senses}, ensure_ascii=False) + "\n")

    batch, translated, n = [], 0, 0
    for lemma, senses in groups.items():
        batch.append({"id": lemma, "s": senses})
        translated += sum(1 for s in senses if "t" in s)
        if translated >= BATCH_TRANSLATED:
            n += 1
            json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
            batch, translated = [], 0
    if batch:
        n += 1
        json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
    total_t = sum(1 for ss in groups.values() for s in ss if "t" in s)
    print(json.dumps({"lemmas": len(groups), "translated_senses": total_t, "batches": n}))


def is_russian(word):
    return any("Ѐ" <= ch <= "ӿ" for ch in word)


def cmd_validate(workdir):
    wd = Path(workdir)
    queue = {}
    for line in open(wd / "queue.jsonl"):
        g = json.loads(line)
        queue[g["id"]] = g

    verdicts = {}
    stats = {"bad_lines": 0}
    for vf in sorted(wd.glob("verdict_*.jsonl")):
        for line in open(vf):
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

    def bad(group, reason):
        requeue.append(group)
        stats[reason] = stats.get(reason, 0) + 1

    for gid, group in queue.items():
        expected = {s["i"]: s for s in group["s"] if "t" in s}
        verdict = verdicts.get(gid)
        if verdict is None:
            bad(group, "missing")
            continue
        if sorted(v.get("i") for v in verdict) != sorted(expected):
            bad(group, "id_mismatch")
            continue
        ok = True
        for v in verdict:
            action = v.get("a")
            if action == "keep":
                counts["kept"] += 1
            elif action == "del":
                counts["deleted"] += 1
            elif action == "rw":
                t = (v.get("t") or "").strip()
                if not (1 <= len(t) <= 40) or not is_russian(t):
                    ok = False
                    bad(group, "rw_shape")
                    break
                if any(ch in t for ch in ",;/()"):
                    ok = False
                    bad(group, "rw_multi")
                    break
                if t.lower() == expected[v["i"]]["t"].lower():
                    ok = False
                    bad(group, "rw_same")
                    break
                counts["rewritten"] += 1
            else:
                ok = False
                bad(group, "bad_action")
                break
        if ok:
            clean.append({"id": gid, "v": verdict})

    with open(wd / "clean_verdicts.jsonl", "w") as f:
        for c in clean:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    with open(wd / "requeue.jsonl", "w") as f:
        for g in requeue:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    stats.update(counts)
    print(json.dumps(stats, indent=1, ensure_ascii=False))
    print(f"clean: {len(clean)}, requeue: {len(requeue)}")


def cmd_apply(clean_path, db_path):
    conn = sqlite3.connect(db_path)
    updated = deleted = 0
    for line in open(clean_path):
        verdict = json.loads(line)
        for v in verdict["v"]:
            if v["a"] == "rw":
                row = conn.execute("SELECT lemma FROM entries WHERE id = ?",
                                   (v["i"],)).fetchone()
                if row and put_translation(conn, v["i"], v["t"], row[0]):
                    updated += 1
            elif v["a"] == "del":
                deleted += conn.execute("DELETE FROM translations WHERE id = ?",
                                        (v["i"],)).rowcount
    conn.commit()
    print(json.dumps({"updated": updated, "deleted": deleted}))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build":
        cmd_build(sys.argv[2], sys.argv[3])
    elif cmd == "validate":
        cmd_validate(sys.argv[2])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
