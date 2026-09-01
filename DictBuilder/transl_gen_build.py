"""Queue + validate + apply for the translation GENERATION swarm.

Targets: senses with no translation, plus senses whose current translation is
wordier than max(2, words in the English lemma). Groups are lemmas with all
senses as context; existing good translations shown as "t", targets marked
"x": 1 (with "t" present when replacing a wordy one).

Verdicts per target: {"i", "a": "add", "t": "..."} | {"i", "a": "skip"}.
Apply: add -> INSERT OR REPLACE; skip on a wordy-current target -> DELETE.

  build <db> <workdir>
  validate <workdir>
  apply <workdir>/clean_verdicts.jsonl <db>
"""
import json, os, sys
import sqlite3
from pathlib import Path

from dictfilters import put_translation

BATCH_TARGETS = 100


def word_limit(lemma):
    return max(2, len(lemma.split()))


def too_wordy(lemma, ru):
    return len(ru.split()) > word_limit(lemma)


def cmd_build(db_path, workdir):
    conn = sqlite3.connect(db_path)
    rows = conn.execute("""
        SELECT e.id, e.lemma, e.pos, e.definition, t.word
        FROM entries e LEFT JOIN translations t ON t.id = e.id
        ORDER BY e.lemma, e.rank, e.id
    """).fetchall()
    groups = {}
    targets = wordy = 0
    for eid, lemma, pos, definition, ru in rows:
        sense = {"i": eid, "p": pos, "d": definition}
        if ru:
            sense["t"] = ru
            if too_wordy(lemma, ru):
                sense["x"] = 1
                wordy += 1
                targets += 1
        else:
            sense["x"] = 1
            targets += 1
        groups.setdefault(lemma, []).append(sense)

    selected = {l: ss for l, ss in groups.items() if any("x" in s for s in ss)}
    os.makedirs(workdir, exist_ok=True)
    with open(f"{workdir}/queue.jsonl", "w") as f:
        for lemma, senses in selected.items():
            f.write(json.dumps({"id": lemma, "s": senses}, ensure_ascii=False) + "\n")

    batch, t, n = [], 0, 0
    for lemma, senses in selected.items():
        batch.append({"id": lemma, "s": senses})
        t += sum(1 for s in senses if "x" in s)
        if t >= BATCH_TARGETS:
            n += 1
            json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
            batch, t = [], 0
    if batch:
        n += 1
        json.dump(batch, open(f"{workdir}/batch_{n:04d}.json", "w"), ensure_ascii=False)
    print(json.dumps({"lemmas": len(selected), "targets": targets,
                      "wordy_replacements": wordy, "batches": n}))


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
    counts = {"added": 0, "skipped": 0}

    def bad(group, reason):
        requeue.append(group)
        stats[reason] = stats.get(reason, 0) + 1

    for gid, group in queue.items():
        expected = {s["i"] for s in group["s"] if "x" in s}
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
            if action == "skip":
                counts["skipped"] += 1
            elif action == "add":
                t = (v.get("t") or "").strip()
                if not (1 <= len(t) <= 40) or not is_russian(t):
                    ok = False
                    bad(group, "t_shape")
                    break
                if any(ch in t for ch in ",;/()"):
                    ok = False
                    bad(group, "t_multi")
                    break
                if too_wordy(gid, t):
                    ok = False
                    bad(group, "t_wordy")
                    break
                counts["added"] += 1
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
    queue_wordy = {}
    wd = Path(clean_path).parent
    for line in open(wd / "queue.jsonl"):
        g = json.loads(line)
        for s in g["s"]:
            if "x" in s and "t" in s:
                queue_wordy[s["i"]] = True
    added = replaced = removed = 0
    for line in open(clean_path):
        verdict = json.loads(line)
        for v in verdict["v"]:
            if v["a"] == "add":
                row = conn.execute("SELECT lemma FROM entries WHERE id = ?",
                                   (v["i"],)).fetchone()
                if row and put_translation(conn, v["i"], v["t"], row[0]):
                    if queue_wordy.get(v["i"]):
                        replaced += 1
                    else:
                        added += 1
            elif v["a"] == "skip" and queue_wordy.get(v["i"]):
                removed += conn.execute("DELETE FROM translations WHERE id = ?",
                                        (v["i"],)).rowcount
    conn.commit()
    print(json.dumps({"added": added, "wordy_replaced": replaced, "wordy_removed": removed}))


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
