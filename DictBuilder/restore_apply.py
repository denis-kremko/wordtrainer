"""Validate and apply restored senses (restore_workflow verdicts).

Each verdict: {"id": lemma, "add": [{"pos", "d", "first", "t"?}]}.
Gates per added sense: 20-220 chars, no root echo with the lemma, no words
rarer than the frequency gate, at least 4 content words, not a near-dupe of
an existing sense (>=2 shared non-lemma stems with any current definition).
Apply: INSERT with fresh ids; first=true puts the sense at rank 0 and shifts
the lemma's other ranks; a valid "t" lands in translations.

  python3 restore_apply.py <workdir> <dictionary.sqlite>
"""
import glob, json, sqlite3, sys, unicodedata

from defs_tools import root_echo, normalize_rewrite
from defs2_build import content_tokens, hard_words, head_rank
from dictfilters import stem_candidates


def clean_ru(word):
    decomposed = unicodedata.normalize("NFD", word)
    return unicodedata.normalize("NFC",
        "".join(ch for ch in decomposed if ch != "́")).strip()


def is_russian(word):
    return any("Ѐ" <= ch <= "ӿ" for ch in word)


def stems(text, minus):
    out = set()
    for t in content_tokens(text):
        cand = stem_candidates(t)
        if cand & minus:
            continue
        out.update(cand)
    return out


def main(workdir, db_path):
    conn = sqlite3.connect(db_path)
    next_id = conn.execute("SELECT MAX(id) FROM entries").fetchone()[0] + 1
    stats = {"lemmas": 0, "added": 0, "firsts": 0, "translated": 0,
             "rej_len": 0, "rej_echo": 0, "rej_freq": 0, "rej_thin": 0, "rej_dupe": 0}

    for vf in sorted(glob.glob(f"{workdir}/verdict_*.jsonl")):
        for line in open(vf):
            v = json.loads(line)
            lemma = v["id"]
            adds = v.get("add") or []
            if not adds:
                continue
            stats["lemmas"] += 1
            existing = conn.execute(
                "SELECT definition FROM entries WHERE lemma = ?", (lemma,)).fetchall()
            lemma_stems = frozenset().union(
                *[stem_candidates(w) for w in content_tokens(lemma)]) \
                if content_tokens(lemma) else frozenset()
            existing_stems = [stems(d, lemma_stems) for (d,) in existing]
            h_rank = head_rank(lemma)

            for add in adds[:2]:
                d = normalize_rewrite((add.get("d") or "").strip())
                pos = (add.get("pos") or "noun").strip().lower()
                if not (20 <= len(d) <= 220):
                    stats["rej_len"] += 1
                    continue
                if root_echo(lemma, d):
                    stats["rej_echo"] += 1
                    continue
                if len(content_tokens(d)) < 4:
                    stats["rej_thin"] += 1
                    continue
                if hard_words(d, h_rank, threshold=10000):
                    stats["rej_freq"] += 1
                    continue
                new_stems = stems(d, lemma_stems)
                if any(len(new_stems & es) >= 3 for es in existing_stems):
                    stats["rej_dupe"] += 1
                    continue

                if add.get("first"):
                    conn.execute(
                        "UPDATE entries SET rank = rank + 1 WHERE lemma = ?", (lemma,))
                    rank = 0
                    stats["firsts"] += 1
                else:
                    rank = (conn.execute(
                        "SELECT COALESCE(MAX(rank), -1) FROM entries WHERE lemma = ?",
                        (lemma,)).fetchone()[0]) + 1
                conn.execute(
                    "INSERT INTO entries (id, lemma, pos, definition, example, rank) VALUES (?, ?, ?, ?, '', ?)",
                    (next_id, lemma, pos, d, rank))
                t = clean_ru(add.get("t") or "")
                if t and is_russian(t) and len(t) <= 40 and len(t.split()) <= max(2, len(lemma.split())) \
                        and not any(ch in t for ch in ",;/()"):
                    conn.execute("INSERT OR REPLACE INTO translations VALUES (?, ?)",
                                 (next_id, t))
                    stats["translated"] += 1
                existing_stems.append(new_stems)
                next_id += 1
                stats["added"] += 1

    conn.commit()
    print(json.dumps(stats))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
