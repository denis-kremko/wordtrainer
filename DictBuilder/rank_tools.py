#!/usr/bin/env python3
"""
Validate and apply LLM sense ranking + near-duplicate removal.

  validate <queue.jsonl> <workdir> — verdicts must partition each group's ids
      into o (kept, most common first, >=1) and x (near-duplicates to delete).
      Writes clean_rank.jsonl + requeue.jsonl.
  apply <clean_rank.jsonl> <dictionary.sqlite> — UPDATE rank, DELETE duplicates.
"""

from __future__ import annotations
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from dictfilters import write_jsonl
from review_tools import load_queue


def cmd_validate(queue_path: str, workdir: str) -> None:
    queue = load_queue(queue_path)
    wd = Path(workdir)

    verdicts: dict[str, dict] = {}
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
            if not isinstance(v, dict) or not isinstance(v.get("id"), str):
                bad_lines += 1
                continue
            verdicts[v["id"]] = v

    clean: list[dict] = []
    requeue: list[dict] = []
    stats = defaultdict(int)

    for gid, row in queue.items():
        ids = {s["i"] for s in row["s"]}
        v = verdicts.get(gid)
        if v is None:
            stats["missing"] += 1
            requeue.append(row)
            continue
        o, x = v.get("o"), v.get("x", [])
        if (not isinstance(o, list) or not isinstance(x, list)
                or not o
                or set(o) | set(x) != ids
                or set(o) & set(x)
                or len(o) + len(x) != len(ids)):
            stats["bad_partition"] += 1
            requeue.append(row)
            continue
        stats["ok"] += 1
        stats["dropped_dupes"] += len(x)
        clean.append({"id": gid, "o": o, "x": x})

    stats["unknown_ids"] = len(set(verdicts) - set(queue))
    stats["bad_lines"] = bad_lines
    write_jsonl(wd / "clean_rank.jsonl", clean)
    write_jsonl(wd / "requeue.jsonl", requeue)
    print(json.dumps(dict(stats), indent=2))
    print(f"clean: {len(clean)}, requeue: {len(requeue)}")


def cmd_apply(clean_path: str, db_path: str) -> None:
    conn = sqlite3.connect(db_path)
    ranks, drops = [], []
    for v in load_queue(clean_path).values():
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
    print(f"applied: {len(ranks)} ranks, {len(drops)} duplicate deletions")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "validate":
        cmd_validate(sys.argv[2], sys.argv[3])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
