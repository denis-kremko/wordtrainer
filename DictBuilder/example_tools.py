#!/usr/bin/env python3
"""
Validate and apply LLM-written usage examples.

  validate <queue.jsonl> <workdir> <dictionary.sqlite>
      Checks verdict_*.jsonl: every id covered; "e" examples must be 4-160
      chars, differ from the definition, and actually use the headword (any
      content word, inflected form, or stem). Writes clean_examples.jsonl and
      requeue.jsonl into the workdir.

  apply <clean_examples.jsonl> <dictionary.sqlite>
      UPDATEs entries.example for rewrite rows ("ok" rows are no-ops).
"""

from __future__ import annotations
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from dictfilters import TOKEN_RE, build_forms_map, content_words, stem_candidates, write_jsonl
from review_tools import load_queue

MIN_LEN = 4
MAX_LEN = 160


def example_uses_lemma(lemma: str, example: str, forms_of: dict[str, set[str]]) -> bool:
    words = content_words(lemma)
    if not words:
        words = tuple(TOKEN_RE.findall(lemma.lower()))
    tokens = set(TOKEN_RE.findall(example.lower()))
    for w in words:
        wc = stem_candidates(w)
        wf = forms_of.get(w) or ()
        if not any(t == w or t in wf or t in wc or bool(stem_candidates(t) & wc) for t in tokens):
            return False
    return True


def cmd_validate(queue_path: str, workdir: str, db_path: str) -> None:
    queue = load_queue(queue_path)
    wanted = {w for r in queue.values() for w in content_words(r["w"])}
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
        if v.get("v") == "ok":
            if row["e"]:
                stats["kept"] += 1
            else:
                stats["ok_without_example"] += 1
                requeue.append(row)
            continue
        e = v.get("e")
        if not isinstance(e, str):
            stats["bad_verdict"] += 1
            requeue.append(row)
            continue
        e = " ".join(e.split())
        if not (MIN_LEN <= len(e) <= MAX_LEN) or e.lower() == row["d"].lower():
            stats["bad_example"] += 1
            requeue.append(row)
            continue
        if not example_uses_lemma(row["w"], e, forms_of):
            stats["lemma_missing"] += 1
            requeue.append(row)
            continue
        stats["written"] += 1
        clean.append({"id": id_, "e": e})

    stats["unknown_ids"] = len(set(verdicts) - set(queue))
    stats["bad_lines"] = bad_lines
    write_jsonl(wd / "clean_examples.jsonl", clean)
    write_jsonl(wd / "requeue.jsonl", requeue)
    print(json.dumps(dict(stats), indent=2))
    print(f"clean: {len(clean)}, requeue: {len(requeue)}")


def cmd_apply(clean_path: str, db_path: str) -> None:
    conn = sqlite3.connect(db_path)
    updates = [(v["e"], v["id"]) for v in load_queue(clean_path).values()]
    conn.executemany("UPDATE entries SET example = ? WHERE id = ?", updates)
    conn.commit()
    conn.close()
    print(f"applied: {len(updates)} examples")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "validate":
        cmd_validate(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
