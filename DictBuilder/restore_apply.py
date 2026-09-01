"""Validate and apply restored senses (restore_workflow verdicts).

Each verdict: {"id": lemma, "add": [{"pos", "d", "first", "t"?}]}.
Gates per added sense: known pos, 20-220 chars, no root echo with the lemma,
not thin, no words rarer than the frequency gate (single-word lemmas only: a
phrase's difficulty is not set by its commonest word), not a dupe of an
existing same-pos sense (verbatim, or >=3 content words sharing a stem).
Apply: INSERT with fresh ids; first=true senses go to ranks 0..k-1 in verdict
order and shift the lemma's other ranks; a valid "t" lands in translations.

  python3 restore_apply.py <workdir> <dictionary.sqlite>
"""
import glob, json, sqlite3, sys

from defs_tools import root_echo, normalize_rewrite
from defs2_build import content_tokens, hard_words, head_rank, is_thin
from dictfilters import put_translation, stem_candidates


def stems(text, minus):
    """Per-token stem-candidate sets; near-dupes count shared TOKENS, not the
    3-6 spelling variants one token expands to."""
    out = []
    for t in content_tokens(text):
        cand = stem_candidates(t)
        if cand & minus:
            continue
        out.append(cand)
    return out


def shared_tokens(new, old):
    return sum(1 for a in new if any(a & b for b in old))


def main(workdir, db_path):
    conn = sqlite3.connect(db_path)
    next_id = conn.execute("SELECT MAX(id) FROM entries").fetchone()[0] + 1
    known_pos = {r[0] for r in conn.execute("SELECT DISTINCT pos FROM entries")}
    stats = {"lemmas": 0, "added": 0, "firsts": 0, "translated": 0,
             "rej_len": 0, "rej_echo": 0, "rej_freq": 0, "rej_thin": 0,
             "rej_dupe": 0, "rej_pos": 0}

    for vf in sorted(glob.glob(f"{workdir}/verdict_*.jsonl")):
        for line in open(vf):
            v = json.loads(line)
            lemma = v["id"]
            adds = v.get("add") or []
            if not adds:
                continue
            stats["lemmas"] += 1
            lemma_stems = frozenset().union(
                *[stem_candidates(w) for w in content_tokens(lemma)]) \
                if content_tokens(lemma) else frozenset()
            existing = [(p, d, stems(d, lemma_stems)) for p, d in conn.execute(
                "SELECT pos, definition FROM entries WHERE lemma = ?", (lemma,))]

            firsts, others = [], []
            for add in adds[:2]:
                d = normalize_rewrite((add.get("d") or "").strip())
                pos = (add.get("pos") or "noun").strip().lower()
                if pos not in known_pos:
                    stats["rej_pos"] += 1
                    continue
                if not (20 <= len(d) <= 220):
                    stats["rej_len"] += 1
                    continue
                if root_echo(lemma, d):
                    stats["rej_echo"] += 1
                    continue
                if is_thin(d):
                    stats["rej_thin"] += 1
                    continue
                if " " not in lemma and hard_words(d, head_rank(lemma), threshold=10000):
                    stats["rej_freq"] += 1
                    continue
                new_stems = stems(d, lemma_stems)
                if any(p == pos and (ed == d or shared_tokens(new_stems, es) >= 3)
                       for p, ed, es in existing):
                    stats["rej_dupe"] += 1
                    continue
                existing.append((pos, d, new_stems))
                (firsts if add.get("first") else others).append((pos, d, add.get("t")))

            if firsts:
                conn.execute(
                    "UPDATE entries SET rank = rank + ? WHERE lemma = ?",
                    (len(firsts), lemma))
                stats["firsts"] += len(firsts)
            placed = list(enumerate(firsts))
            if others:
                next_rank = (conn.execute(
                    "SELECT COALESCE(MAX(rank), -1) FROM entries WHERE lemma = ?",
                    (lemma,)).fetchone()[0]) + 1
                # A lemma with no rows yet: firsts already occupy 0..k-1.
                next_rank = max(next_rank, len(firsts))
                placed += [(next_rank + i, a) for i, a in enumerate(others)]

            for rank, (pos, d, t_raw) in placed:
                conn.execute(
                    "INSERT INTO entries (id, lemma, pos, definition, example, rank) VALUES (?, ?, ?, ?, '', ?)",
                    (next_id, lemma, pos, d, rank))
                if put_translation(conn, next_id, t_raw or "", lemma):
                    stats["translated"] += 1
                next_id += 1
                stats["added"] += 1

    conn.commit()
    print(json.dumps(stats))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
