"""Per-sense Russian translations matched by ORIGINAL gloss text.

The id counter of the original build is not reproducible, but every live id's
pre-rewrite definition survives in the defs queue snapshot. Kaikki senses are
keyed by (lemma, pos, cleaned gloss); live ids resolve through their original
text (exact, then lightly normalized).

  python3 sense_translations_match.py <kaikki.jsonl> <defs_queue.jsonl> <dictionary.sqlite>

Writes translations(id INTEGER PRIMARY KEY, word TEXT).
"""
import json, sqlite3, sys, unicodedata
from pathlib import Path

import build_dict as bd


def clean_ru(word):
    decomposed = unicodedata.normalize("NFD", word)
    stripped = "".join(ch for ch in decomposed if ch != "́")
    return unicodedata.normalize("NFC", stripped).strip()


def is_russian(word):
    return any("Ѐ" <= ch <= "ӿ" for ch in word)


def first_russian(sense):
    for t in sense.get("translations") or []:
        if t.get("code") != "ru" or not t.get("word"):
            continue
        w = clean_ru(t["word"])
        if w and len(w) <= 40 and is_russian(w):
            return w
    return None


def soft(gloss):
    return gloss.lower().rstrip(".").strip()


def main():
    kaikki_path, queue_path, db_path = sys.argv[1], sys.argv[2], sys.argv[3]

    exact = {}
    softmap = {}
    for obj in bd.iter_dump(Path(kaikki_path), "kaikki ru"):
        word = obj.get("word", "")
        if not isinstance(word, str) or not word:
            continue
        lemma = word.lower()
        pos = obj.get("pos", "") or ""
        for sense in obj.get("senses") or []:
            glosses = sense.get("glosses") or []
            if not glosses:
                continue
            ru = first_russian(sense)
            if not ru:
                continue
            gloss = bd.strip_grammar_label(bd.clean_gloss(glosses[-1]))
            exact.setdefault((lemma, pos, gloss), ru)
            softmap.setdefault((lemma, pos, soft(gloss)), ru)

    originals = {}
    for line in open(queue_path):
        g = json.loads(line)
        lemma, pos = g["id"].rsplit("|", 1)
        for s in g["s"]:
            originals[s["i"]] = (lemma, pos, s["d"])

    conn = sqlite3.connect(db_path)
    rows = []
    hits_exact = hits_soft = hits_current = 0
    for eid, lemma, pos, definition in conn.execute("SELECT id, lemma, pos, definition FROM entries"):
        ru = None
        if eid in originals:
            olemma, opos, od = originals[eid]
            ru = exact.get((olemma, opos, od))
            if ru:
                hits_exact += 1
            else:
                ru = softmap.get((olemma, opos, soft(od)))
                if ru:
                    hits_soft += 1
        if not ru:
            ru = exact.get((lemma, pos, definition)) or softmap.get((lemma, pos, soft(definition)))
            if ru:
                hits_current += 1
        if ru:
            rows.append((eid, ru))

    conn.execute("DROP TABLE IF EXISTS translations")
    conn.execute("CREATE TABLE translations (id INTEGER PRIMARY KEY, word TEXT NOT NULL)")
    conn.executemany("INSERT INTO translations VALUES (?, ?)", rows)
    conn.commit()
    print(json.dumps({"kaikki_ru_senses": len(exact), "translated_ids": len(rows),
                      "exact": hits_exact, "soft": hits_soft, "current": hits_current}))


if __name__ == "__main__":
    main()
