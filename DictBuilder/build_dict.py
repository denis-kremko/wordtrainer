#!/usr/bin/env python3
"""
Build an offline English dictionary SQLite from a Kaikki (Wiktextract) JSONL dump.

Usage:
    # 1. Download the English dump (~1.3 GB compressed, ~9 GB uncompressed):
    #    https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl
    # 2. Run:
    python3 build_dict.py kaikki.org-dictionary-English.jsonl dictionary.sqlite

Output DB schema:
    entries(id INTEGER PK, lemma TEXT, pos TEXT, definition TEXT, example TEXT)
    forms(form TEXT, lemma TEXT)         -- e.g. came -> come, gone -> go
    idx_entries_lemma ON entries(lemma)
    idx_forms_form    ON forms(form)

Aggressive filtering rules (target ~60 MB output):
  * ASCII-only headwords: skip anything with characters outside
    [a-zA-Z' -]. Drops accented/dotted forms as a size tradeoff.
  * Drop obsolete/archaic/dated/rare/dialectal/proscribed/informal-tag-only senses.
  * Drop cross-reference definitions ("Alternative form of X", "Plural of X", etc.).
  * Drop definitions shorter than 8 chars or longer than 200 chars.
  * Keep at most 3 senses per (word, POS) JSONL entry.
  * Keep at most 1 short example per sense (shortest, ≤160 chars).
  * Skip POS values that are not real word categories (name, symbol, ...).

The `forms` table maps inflected forms (came, gone, running, mice) back to base
lemmas (come, go, run, mouse) so the UI can suggest "did you mean X?" when the
user types an inflection.
"""

from __future__ import annotations
import json
import re
import sqlite3
import sys
from pathlib import Path

# Prefixes that indicate the "definition" is just a cross-reference to another
# lemma. Users learning vocabulary don't want to see these.
DROP_PREFIXES = (
    "alternative form of",
    "alternative spelling of",
    "alternative letter-case form of",
    "obsolete form of",
    "obsolete spelling of",
    "misspelling of",
    "archaic form of",
    "archaic spelling of",
    "dated form of",
    "dated spelling of",
    "rare spelling of",
    "eye dialect of",
    "informal spelling of",
    "informal form of",
    "pronunciation spelling of",
    "clipping of",
    "abbreviation of",
    "initialism of",
    "acronym of",
    "contraction of",
    "synonym of",
    "plural of",
    "simple past of",
    "past tense of",
    "past participle of",
    "present participle of",
    "gerund of",
    "third-person singular of",
    "singular of",
    "comparative of",
    "superlative of",
    "diminutive of",
    "augmentative of",
    "feminine of",
    "masculine of",
    "inflection of",
    "romanization of",
    "used other than figuratively",
    "used other than with a figurative",
)

# Tags on a sense that indicate it's not useful for a modern learner.
DROP_TAGS = frozenset({
    "obsolete", "archaic", "dated", "historical", "rare",
    "dialectal", "proscribed", "nonstandard", "vulgar",
    "offensive", "derogatory", "slur",
})

# POS values we skip entirely — they aren't the kinds of "words" a learner wants.
DROP_POS = frozenset({
    "name", "prop", "proper noun",
    "symbol", "punct", "punctuation",
    "character", "letter", "romanization",
    "num", "affix", "prefix", "suffix", "infix", "combining_form",
    "phrase-book",
})

MAX_SENSES_PER_ENTRY = 3
MIN_GLOSS_LEN = 8
MAX_GLOSS_LEN = 200
MAX_EXAMPLE_LEN = 160
MAX_FORMS_PER_LEMMA = 12  # cap to keep the forms table bounded

LEMMA_OK = re.compile(r"^[a-zA-Z][a-zA-Z' \-]*$")

_MAX_PREFIX_LEN = max(len(p) for p in DROP_PREFIXES)

# Parenthetical tags at the start of a gloss like "(obsolete)", "(archaic, rare)".
_PAREN_TAG_RE = re.compile(r"^\s*\(([^)]{1,60})\)\s*")


def clean_gloss(g: str) -> str:
    return " ".join(g.split())


def gloss_starts_with_bad_tag(gloss: str) -> bool:
    m = _PAREN_TAG_RE.match(gloss)
    if not m:
        return False
    tags = {t.strip().lower() for t in m.group(1).split(",")}
    return bool(tags & DROP_TAGS)


def keep_gloss(g: str) -> bool:
    n = len(g)
    if n < MIN_GLOSS_LEN or n > MAX_GLOSS_LEN:
        return False
    if g[:_MAX_PREFIX_LEN].lower().startswith(DROP_PREFIXES):
        return False
    if gloss_starts_with_bad_tag(g):
        return False
    return True


def sense_has_bad_tag(sense: dict) -> bool:
    tags = sense.get("tags") or []
    if isinstance(tags, list):
        for t in tags:
            if isinstance(t, str) and t.lower() in DROP_TAGS:
                return True
    return False


def pick_example(sense: dict) -> str:
    examples = sense.get("examples") or []
    best = ""
    for e in examples:
        t = e.get("text") if isinstance(e, dict) else None
        if not isinstance(t, str):
            continue
        t = t.strip()
        n = len(t)
        if 4 < n <= MAX_EXAMPLE_LEN:
            if not best or n < len(best):
                best = t
    return best


def extract_forms(obj: dict) -> list[str]:
    """Pull inflected-form strings out of a Kaikki entry."""
    out: list[str] = []
    forms = obj.get("forms") or []
    if not isinstance(forms, list):
        return out
    seen: set[str] = set()
    for f in forms:
        if not isinstance(f, dict):
            continue
        form = f.get("form")
        if not isinstance(form, str):
            continue
        form = form.strip().lower()
        if not form or form in seen:
            continue
        # Skip tags-only rows (Kaikki sometimes lists a shape without a form),
        # non-ASCII, and multi-word "forms" (usually periphrastic constructions).
        if not LEMMA_OK.match(form):
            continue
        # Filter obvious non-inflections: canonical / lemma / romanization tags.
        tags = f.get("tags") or []
        if isinstance(tags, list):
            tag_set = {t.lower() for t in tags if isinstance(t, str)}
            if "canonical" in tag_set or "romanization" in tag_set or "table-tags" in tag_set:
                continue
        seen.add(form)
        out.append(form)
        if len(out) >= MAX_FORMS_PER_LEMMA:
            break
    return out


def main(src: str, dst: str) -> None:
    src_path = Path(src)
    dst_path = Path(dst)
    if not src_path.exists():
        print(f"ERROR: source file not found: {src_path}", file=sys.stderr)
        sys.exit(1)
    if dst_path.exists():
        dst_path.unlink()

    conn = sqlite3.connect(dst_path)
    cur = conn.cursor()
    cur.execute("PRAGMA journal_mode=OFF")
    cur.execute("PRAGMA synchronous=OFF")
    cur.execute("""
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            lemma TEXT NOT NULL,
            pos TEXT NOT NULL,
            definition TEXT NOT NULL,
            example TEXT
        )
    """)
    cur.execute("""
        CREATE TABLE forms (
            form TEXT NOT NULL,
            lemma TEXT NOT NULL
        )
    """)

    total_in = 0
    total_senses = 0
    total_forms = 0
    entry_batch: list[tuple[str, str, str, str]] = []
    form_batch: list[tuple[str, str]] = []
    insert_entry = "INSERT INTO entries (lemma, pos, definition, example) VALUES (?, ?, ?, ?)"
    insert_form = "INSERT INTO forms (form, lemma) VALUES (?, ?)"

    def flush() -> None:
        if entry_batch:
            cur.executemany(insert_entry, entry_batch)
            entry_batch.clear()
        if form_batch:
            cur.executemany(insert_form, form_batch)
            form_batch.clear()

    with src_path.open("r", encoding="utf-8") as f:
        for line in f:
            total_in += 1
            if total_in % 100000 == 0:
                print(f"  processed {total_in:,} lines, kept {total_senses:,} senses, {total_forms:,} forms")
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            word = obj.get("word", "")
            if not isinstance(word, str) or not LEMMA_OK.match(word):
                continue
            pos = obj.get("pos", "")
            if not isinstance(pos, str) or not pos or pos.lower() in DROP_POS:
                continue

            lemma = word.lower()
            senses = obj.get("senses") or []
            kept_here = 0
            for sense in senses:
                if kept_here >= MAX_SENSES_PER_ENTRY:
                    break
                if sense_has_bad_tag(sense):
                    continue
                glosses = sense.get("glosses") or []
                if not glosses:
                    continue
                gloss = clean_gloss(glosses[-1])
                if not keep_gloss(gloss):
                    continue
                example = pick_example(sense)
                entry_batch.append((lemma, pos, gloss, example))
                kept_here += 1
                total_senses += 1

            # Only bother emitting forms for words we actually kept senses for.
            if kept_here > 0:
                for form in extract_forms(obj):
                    if form != lemma:
                        form_batch.append((form, lemma))
                        total_forms += 1

            if len(entry_batch) >= 5000 or len(form_batch) >= 5000:
                flush()

    flush()

    print("Creating indexes...")
    cur.execute("CREATE INDEX idx_entries_lemma ON entries(lemma)")
    cur.execute("CREATE INDEX idx_forms_form ON forms(form)")
    conn.commit()
    conn.close()

    size_mb = dst_path.stat().st_size / (1024 * 1024)
    print(f"Done. Read {total_in:,} lines, kept {total_senses:,} senses, {total_forms:,} forms.")
    print(f"Output: {dst_path} — {size_mb:.1f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: build_dict.py <kaikki.jsonl> <output.sqlite>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
