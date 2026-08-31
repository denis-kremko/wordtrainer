#!/usr/bin/env python3
"""
Tooling around the LLM review of flagged dictionary senses.

  split    — cut review_queue.jsonl into batch_NNNN.json files for review agents
  validate — check verdict_NNNN.jsonl files: coverage, format, rewrite quality;
             writes clean_verdicts.jsonl + requeue.jsonl (items needing another pass)
  apply    — apply clean_verdicts.jsonl to the sqlite (UPDATE rewrites, DELETE drops)

Usage:
  python3 review_tools.py split    <review_queue.jsonl> <workdir> [batch_size]
  python3 review_tools.py validate <review_queue.jsonl> <workdir> <dictionary.sqlite>
  python3 review_tools.py apply    <clean_verdicts.jsonl> <dictionary.sqlite>
"""

from __future__ import annotations
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from build_dict import gloss_is_droppable
from dictfilters import build_forms_map, content_words, self_ref_token, write_jsonl


def load_queue(path: str) -> dict[int, dict]:
    rows = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            rows[r["id"]] = r
    return rows


def cmd_split(queue_path: str, workdir: str, batch_size: int = 150) -> None:
    out = Path(workdir)
    out.mkdir(parents=True, exist_ok=True)
    rows = list(load_queue(queue_path).values())
    batches = []
    for i in range(0, len(rows), batch_size):
        n = f"{i // batch_size + 1:04d}"
        batch = rows[i : i + batch_size]
        (out / f"batch_{n}.json").write_text(json.dumps(batch, ensure_ascii=False, indent=0))
        batches.append({
            "n": n,
            "in": str(out / f"batch_{n}.json"),
            "out": str(out / f"verdict_{n}.jsonl"),
            "count": len(batch),
        })
    (out / "batches.json").write_text(json.dumps(batches))
    print(f"{len(rows)} items -> {len(batches)} batches in {out}/")


def cmd_validate(queue_path: str, workdir: str, db_path: str) -> None:
    queue = load_queue(queue_path)
    wanted = {w for r in queue.values() for w in content_words(r["lemma"])}
    forms_of = {k: v for k, v in build_forms_map(db_path).items() if k in wanted}
    wd = Path(workdir)

    verdicts: dict[int, dict] = {}
    bad_lines = 0
    for vf in sorted(wd.glob("verdict_*.jsonl")):
        for line in vf.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                v = json.loads(line)
            except json.JSONDecodeError:
                bad_lines += 1
                continue
            if not isinstance(v, dict) or type(v.get("id")) is not int:
                bad_lines += 1
                continue
            verdicts[v["id"]] = v

    clean: list[dict] = []
    requeue: list[dict] = []
    stats = defaultdict(int)

    for id_, row in queue.items():
        v = verdicts.get(id_)
        if v is None:
            stats["missing"] += 1
            requeue.append(row)
            continue
        verdict = v.get("v")
        if verdict == "keep":
            stats["keep"] += 1
            clean.append({"id": id_, "v": "keep"})
        elif verdict == "drop":
            stats["drop"] += 1
            clean.append({"id": id_, "v": "drop"})
        elif verdict == "rewrite":
            d = v.get("d")
            if not isinstance(d, str):
                stats["bad_rewrite"] += 1
                requeue.append(row)
                continue
            d = " ".join(d.split())
            if gloss_is_droppable(d):
                stats["rewrite_droppable"] += 1
                requeue.append(row)
                continue
            if self_ref_token(row["lemma"], d, forms_of):
                stats["rewrite_still_self_ref"] += 1
                requeue.append(row)
                continue
            stats["rewrite"] += 1
            clean.append({"id": id_, "v": "rewrite", "d": d})
        else:
            stats["bad_verdict"] += 1
            requeue.append(row)

    unknown_ids = set(verdicts) - set(queue)
    stats["unknown_ids"] = len(unknown_ids)
    stats["bad_lines"] = bad_lines

    write_jsonl(wd / "clean_verdicts.jsonl", clean)
    write_jsonl(wd / "requeue.jsonl", requeue)

    print(json.dumps(dict(stats), indent=2))
    print(f"clean: {len(clean)}, requeue: {len(requeue)}")


def cmd_apply(clean_path: str, db_path: str) -> None:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    drops, rewrites = [], []
    for v in load_queue(clean_path).values():
        if v["v"] == "drop":
            drops.append((v["id"],))
        elif v["v"] == "rewrite":
            rewrites.append((v["d"], v["id"]))
    cur.executemany("DELETE FROM entries WHERE id = ?", drops)
    cur.executemany("UPDATE entries SET definition = ? WHERE id = ?", rewrites)
    conn.commit()
    cur.execute("DELETE FROM forms WHERE lemma NOT IN (SELECT DISTINCT lemma FROM entries)")
    conn.commit()
    cur.execute("VACUUM")
    conn.close()
    print(f"applied: {len(drops)} drops, {len(rewrites)} rewrites")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "split":
        cmd_split(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 150)
    elif cmd == "validate":
        cmd_validate(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
