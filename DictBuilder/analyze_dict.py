#!/usr/bin/env python3
"""
Flag suspicious dictionary entries for review. Does NOT modify anything.

Flags:
  self_ref — the definition contains the headword itself, one of its inflected
             forms (via the `forms` table), or a direct suffix derivation
             (quick/quickly, come/coming). For multiword lemmas each content
             word is checked ("come on" flagged for "To come upon").
  complex  — the definition is long/convoluted by structural heuristics.
  rare     — the lemma is absent from both web (Norvig count_1w) and subtitle
             (OpenSubtitles) frequency lists at generous thresholds.

All heuristics are imported from dictfilters so the analyzer always agrees
with what build_dict.py actually does.

Usage:
    python3 analyze_dict.py dictionary.sqlite norvig_count_1w.txt opensubs_en_full.txt out_dir
"""

from __future__ import annotations
import json
import random
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from dictfilters import FrequencyFilter, build_forms_map, is_complex, self_ref_token


def main(db_path: str, norvig_path: str, subs_path: str, out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    freq = FrequencyFilter(norvig_path, subs_path)

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    forms_of = build_forms_map(db_path)

    self_ref: list[dict] = []
    complex_: list[dict] = []
    rare_lemmas: dict[str, list[dict]] = defaultdict(list)
    total = 0
    lemmas: set[str] = set()

    for id_, lemma, pos, definition in cur.execute("SELECT id, lemma, pos, definition FROM entries"):
        total += 1
        lemmas.add(lemma)
        row = {"id": id_, "lemma": lemma, "pos": pos, "definition": definition}
        hit = self_ref_token(lemma, definition, forms_of)
        if hit:
            self_ref.append({**row, "match": hit})
        if is_complex(definition):
            complex_.append(row)
        if not freq.lemma_is_common(lemma):
            rare_lemmas[lemma].append(row)

    rare_count = sum(len(v) for v in rare_lemmas.values())
    stats = {
        "total_senses": total,
        "total_lemmas": len(lemmas),
        "self_ref_senses": len(self_ref),
        "complex_senses": len(complex_),
        "rare_lemmas": len(rare_lemmas),
        "rare_senses": rare_count,
    }
    print(json.dumps(stats, indent=2))

    rng = random.Random(42)
    for name, rows in [("self_ref", self_ref), ("complex", complex_)]:
        sample = rng.sample(rows, min(60, len(rows)))
        (out / f"sample_{name}.json").write_text(json.dumps(sample, indent=1, ensure_ascii=False))
        (out / f"all_{name}.json").write_text(json.dumps(rows, ensure_ascii=False))

    rare_sample_lemmas = rng.sample(sorted(rare_lemmas), min(80, len(rare_lemmas)))
    rare_sample = [rare_lemmas[l][0] for l in rare_sample_lemmas]
    (out / "sample_rare.json").write_text(json.dumps(rare_sample, indent=1, ensure_ascii=False))
    (out / "all_rare_lemmas.txt").write_text("\n".join(sorted(rare_lemmas)))
    (out / "stats.json").write_text(json.dumps(stats, indent=2))
    print(f"Samples written to {out}/")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    main(*sys.argv[1:])
