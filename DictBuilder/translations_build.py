"""Russian translations from the kaikki dump into the dictionary database.

  build <kaikki.jsonl.gz> <dictionary.sqlite>

Creates translations(lemma, word, rank): entry-level and sense-level Russian
translations merged in file order, deduped case-insensitively, stress marks
stripped, up to 6 per lemma, only for lemmas the dictionary actually has.
"""
import gzip, json, sqlite3, sys, unicodedata

MAX_PER_LEMMA = 6


def clean(word):
    # Wiktionary marks stress with combining acute accents; readers don't
    # need them and they render inconsistently.
    decomposed = unicodedata.normalize("NFD", word)
    stripped = "".join(ch for ch in decomposed if ch != "́")
    return unicodedata.normalize("NFC", stripped).strip()


def is_russian(word):
    return any("Ѐ" <= ch <= "ӿ" for ch in word)


def cmd_build(kaikki_path, db_path):
    conn = sqlite3.connect(db_path)
    lemmas = {r[0] for r in conn.execute("SELECT DISTINCT lemma FROM entries")}
    out = {}
    scanned = 0
    with gzip.open(kaikki_path, "rt") as f:
        for line in f:
            scanned += 1
            try:
                e = json.loads(line)
            except Exception:
                continue
            word = (e.get("word") or "").lower()
            if word not in lemmas:
                continue
            candidates = []
            for t in e.get("translations") or []:
                if t.get("code") == "ru" and t.get("word"):
                    candidates.append(t["word"])
            for s in e.get("senses") or []:
                for t in s.get("translations") or []:
                    if t.get("code") == "ru" and t.get("word"):
                        candidates.append(t["word"])
            if not candidates:
                continue
            bucket = out.setdefault(word, [])
            seen = {w.lower() for w in bucket}
            for raw in candidates:
                w = clean(raw)
                if not w or len(w) > 40 or not is_russian(w):
                    continue
                if w.lower() in seen:
                    continue
                seen.add(w.lower())
                bucket.append(w)

    conn.execute("DROP TABLE IF EXISTS translations")
    conn.execute("CREATE TABLE translations (lemma TEXT NOT NULL, word TEXT NOT NULL, rank INTEGER NOT NULL)")
    rows = []
    for lemma, words in out.items():
        for i, w in enumerate(words[:MAX_PER_LEMMA]):
            rows.append((lemma, w, i))
    conn.executemany("INSERT INTO translations VALUES (?, ?, ?)", rows)
    conn.execute("CREATE INDEX idx_translations_lemma ON translations(lemma)")
    conn.commit()
    print(json.dumps({"scanned": scanned, "lemmas_with_ru": len(out), "rows": len(rows)}))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    cmd_build(sys.argv[1], sys.argv[2])
