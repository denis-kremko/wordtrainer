"""Per-SENSE Russian translations, keyed by the original stable entry ids.

Replays build_dict's deterministic two-pass walk over the kaikki dump (same
filters, same id counter) while keeping each kaikki sense object, then takes
the first sense-level Russian translation per id. Ids are validated against
the live database: every (id, lemma, pos) present in it must match the
replayed walk exactly, otherwise the run aborts.

  python3 sense_translations_build.py <kaikki.jsonl.gz> <dictionary.sqlite> \
      [--norvig /tmp/count_1w.txt] [--subs /tmp/en_full.txt]

Writes translations(id INTEGER PRIMARY KEY, word TEXT).
"""
import argparse, json, sqlite3, sys, unicodedata
from pathlib import Path

import build_dict as bd


def clean(word):
    decomposed = unicodedata.normalize("NFD", word)
    stripped = "".join(ch for ch in decomposed if ch != "́")
    return unicodedata.normalize("NFC", stripped).strip()


def is_russian(word):
    return any("Ѐ" <= ch <= "ӿ" for ch in word)


def first_russian(sense):
    for t in sense.get("translations") or []:
        if t.get("code") != "ru" or not t.get("word"):
            continue
        w = clean(t["word"])
        if w and len(w) <= 40 and is_russian(w):
            return w
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("db")
    ap.add_argument("--norvig", default="/tmp/count_1w.txt")
    ap.add_argument("--subs", default="/tmp/en_full.txt")
    args = ap.parse_args()
    src_path = Path(args.src)

    freq = bd.FrequencyFilter(args.norvig, args.subs)
    forms_of = bd.collect_forms_map(src_path, freq)

    next_id = 1
    id_meta = {}          # id -> (lemma, pos), for the determinism check
    ru_by_id = {}

    for obj in bd.iter_dump(src_path, "sense translations"):
        word = obj.get("word", "")
        if not isinstance(word, str) or not bd.LEMMA_OK.match(word):
            continue
        pos = obj.get("pos", "")
        if not isinstance(pos, str) or not pos or pos.lower() in bd.DROP_POS:
            continue
        lemma = word.lower()
        if not freq.lemma_is_common(lemma):
            continue
        multiword = (" " in lemma) or ("-" in lemma)

        candidates = []
        overlong = []
        for sense in obj.get("senses") or []:
            if bd.sense_has_bad_tag(sense):
                continue
            glosses = sense.get("glosses") or []
            if not glosses:
                continue
            gloss = bd.strip_grammar_label(bd.clean_gloss(glosses[-1]))
            if bd.gloss_is_droppable(gloss):
                if bd.MAX_GLOSS_LEN < len(gloss) <= bd.OVERLONG_RESCUE_MAX \
                        and not bd.gloss_content_droppable(gloss):
                    overlong.append((gloss, sense))
                continue
            echo = bd.self_ref_token(lemma, gloss, forms_of)
            if not multiword and echo and bd.STUB_RE.match(gloss):
                flag = "stub"
            elif multiword and bd.is_circular_multiword(lemma, gloss):
                flag = "circular"
            elif not multiword and echo:
                flag = "self_ref"
            elif bd.is_complex(gloss):
                flag = "complex"
            else:
                flag = None
            candidates.append((gloss, sense, flag))

        real = [c for c in candidates if c[2] != "stub"][:bd.MAX_SENSES_PER_ENTRY]
        if real:
            kept = [(g, s) for g, s, _ in real]
        elif candidates:
            kept = [(candidates[0][0], candidates[0][1])]
        elif overlong:
            kept = [overlong[0]]
        else:
            kept = []

        for _, sense in kept:
            id_meta[next_id] = (lemma, pos)
            ru = first_russian(sense)
            if ru:
                ru_by_id[next_id] = ru
            next_id += 1

    conn = sqlite3.connect(args.db)
    mismatches = 0
    live = 0
    for eid, lemma, pos in conn.execute("SELECT id, lemma, pos FROM entries"):
        live += 1
        if id_meta.get(eid) != (lemma, pos):
            mismatches += 1
    if mismatches:
        sys.exit(f"ID DETERMINISM BROKEN: {mismatches} of {live} live ids mismatch — aborting.")

    live_ids = {r[0] for r in conn.execute("SELECT id FROM entries")}
    rows = [(eid, w) for eid, w in ru_by_id.items() if eid in live_ids]
    conn.execute("DROP TABLE IF EXISTS translations")
    conn.execute("CREATE TABLE translations (id INTEGER PRIMARY KEY, word TEXT NOT NULL)")
    conn.executemany("INSERT INTO translations VALUES (?, ?)", rows)
    conn.commit()
    print(json.dumps({"walked_ids": next_id - 1, "live_ids": live,
                      "sense_translations": len(rows)}))


if __name__ == "__main__":
    main()
