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
from review_tools import load_queue, load_verdicts

MIN_LEN = 4
MAX_LEN = 160


def lemma_words(lemma: str) -> tuple[str, ...]:
    """Words an example must use: content words, else every raw token (so short
    or stopword-only headwords like "go"/"do in" still get checked — and their
    forms stay in the map cmd_validate builds)."""
    return content_words(lemma) or tuple(TOKEN_RE.findall(lemma.lower()))


def example_uses_lemma(lemma: str, example: str, forms_of: dict[str, set[str]]) -> bool:
    words = lemma_words(lemma)
    tokens = set(TOKEN_RE.findall(example.lower()))
    for w in words:
        wc = stem_candidates(w)
        wf = forms_of.get(w) or ()
        if not any(t == w or t in wf or t in wc or bool(stem_candidates(t) & wc) for t in tokens):
            return False
    return True


def cmd_validate(queue_path: str, workdir: str, db_path: str) -> None:
    queue = load_queue(queue_path)
    wanted = {w for r in queue.values() for w in lemma_words(r["w"])}
    forms_of = build_forms_map(db_path, wanted)
    wd = Path(workdir)
    verdicts, bad_lines = load_verdicts(wd)

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
    cur = conn.executemany("UPDATE entries SET example = ? WHERE id = ?", updates)
    applied = cur.rowcount  # ids deleted since validation match no rows
    conn.commit()
    conn.close()
    print(f"applied: {applied} of {len(updates)} examples")
    if applied != len(updates):
        print(f"WARNING: {len(updates) - applied} ids no longer exist in entries")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "validate":
        cmd_validate(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
