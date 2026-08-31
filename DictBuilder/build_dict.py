#!/usr/bin/env python3
"""
Build an offline English dictionary SQLite from a Kaikki (Wiktextract) JSONL dump.

Usage:
    python3 build_dict.py kaikki.jsonl dictionary.sqlite \
        --norvig count_1w.txt --subs en_full.txt --review-queue review_queue.jsonl

Output DB schema:
    entries(id INTEGER PK, lemma TEXT, pos TEXT, definition TEXT, example TEXT)
    forms(form TEXT, lemma TEXT)         -- e.g. came -> come, gone -> go
    idx_entries_lemma ON entries(lemma)
    idx_forms_form    ON forms(form)

Filtering (v2):
  * ASCII-only headwords (as v1).
  * Frequency filter: every content word of the lemma must appear in the Norvig
    web list (top 100k) or the OpenSubtitles list (top 250k). Kills taxonomy,
    chemistry, nonce words; keeps rare-but-real learner words.
  * Inflection cross-references dropped by regex ("present participle and gerund
    of X", "third-person singular ... of X") — these are covered by `forms`.
    The gloss must START with an unambiguous morphology word, so real glosses
    like "Standard of living." survive.
  * Derivational stubs ("One who abandons", "In an abashed manner") — stub shape
    AND a root echo of the headword required ("theft: The act of stealing." is
    NOT a stub) — dropped when the entry keeps at least one real sense; kept
    (flagged) when it is all there is.
  * Leading pure-grammar parenthetical labels stripped ("(transitive) To ..." -> "To ...").
  * Senses that echo the headword (self_ref), short circular multiword glosses
    (circular), and long convoluted glosses (complex) are KEPT but written to the
    review queue for an LLM/manual pass — nothing is silently dropped there.
  * Drop obsolete/archaic/... tags, bad POS, 8..200 char glosses, <=3 senses per
    (word, POS), <=1 example per sense — as v1.

The review queue is JSONL: {"id", "lemma", "pos", "definition", "flag", "only_sense"}
where id is the entries.id of the row in the output DB.
"""

from __future__ import annotations
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
import sqlite3

from dictfilters import (
    CROSS_REF_RE, MAX_GLOSS_LEN, MIN_GLOSS_LEN, STUB_RE, FrequencyFilter,
    create_indexes, create_schema, is_circular_multiword, is_complex,
    leading_paren_labels, self_ref_token, strip_grammar_label, write_jsonl,
)

DROP_PREFIXES = (
    "alternative form of", "alternative spelling of", "alternative letter-case form of",
    "obsolete form of", "obsolete spelling of", "misspelling of",
    "archaic form of", "archaic spelling of", "dated form of", "dated spelling of",
    "rare spelling of", "rare form of", "eye dialect of",
    "informal spelling of", "informal form of", "pronunciation spelling of",
    "clipping of", "abbreviation of", "initialism of", "acronym of", "contraction of",
    "synonym of", "plural of", "simple past of", "past tense of", "past participle of",
    "present participle of", "gerund of", "third-person singular of", "singular of",
    "comparative of", "superlative of", "diminutive of", "augmentative of",
    "feminine of", "masculine of", "inflection of", "romanization of",
    "standard spelling of", "standard form of", "nonstandard spelling of",
    "nonstandard form of", "alternative case form of", "ellipsis of", "short for ",
    "used other than figuratively", "used other than with a figurative",
)

# NOTE: "historical" is deliberately NOT here: obsolete/archaic mark dead WORDS,
# but historical marks past THINGS named by living words (felony, musket).
DROP_TAGS = frozenset({
    "obsolete", "archaic", "dated", "rare",
    "dialectal", "proscribed", "nonstandard", "vulgar",
    "offensive", "derogatory", "slur",
})

DROP_POS = frozenset({
    "name", "prop", "proper noun",
    "symbol", "punct", "punctuation",
    "character", "letter", "romanization",
    "num", "affix", "prefix", "suffix", "infix", "combining_form",
    "phrase-book",
})

MAX_SENSES_PER_ENTRY = 3
MAX_EXAMPLE_LEN = 160
MAX_FORMS_PER_LEMMA = 12
# Entries whose every sense is droppable may rescue ONE gloss that failed only
# the length cap (200 < len <= this) — never one that is also a cross-ref,
# drop-prefix, or bad-tag gloss.
OVERLONG_RESCUE_MAX = 320

LEMMA_OK = re.compile(r"^(?!.*  )[a-zA-Z](?:[a-zA-Z' \-]*[a-zA-Z'])?$")

_MAX_PREFIX_LEN = max(len(p) for p in DROP_PREFIXES)


def clean_gloss(g: str) -> str:
    return " ".join(g.split())


def gloss_starts_with_bad_tag(gloss: str) -> bool:
    labels, _ = leading_paren_labels(gloss)
    return labels is not None and bool(labels & DROP_TAGS)


def gloss_content_droppable(g: str) -> bool:
    if g[:_MAX_PREFIX_LEN].lower().startswith(DROP_PREFIXES):
        return True
    if gloss_starts_with_bad_tag(g):
        return True
    if CROSS_REF_RE.match(g):
        return True
    return False


def gloss_is_droppable(g: str) -> bool:
    return not (MIN_GLOSS_LEN <= len(g) <= MAX_GLOSS_LEN) or gloss_content_droppable(g)


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
        if not LEMMA_OK.match(form):
            continue
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


def iter_dump(src_path: Path, label: str, prescreen: str | None = None):
    with src_path.open("r", encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if n % 300000 == 0:
                print(f"  {label}: {n:,} lines")
            if prescreen is not None and prescreen not in line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def collect_forms_map(src_path: Path, freq: FrequencyFilter) -> dict[str, set[str]]:
    """Pass 1: inflected forms of common single-word lemmas, for self-ref checks."""
    forms_of: dict[str, set[str]] = defaultdict(set)
    for obj in iter_dump(src_path, "pass 1", prescreen='"forms"'):
        word = obj.get("word", "")
        if not isinstance(word, str) or " " in word or not LEMMA_OK.match(word):
            continue
        w = word.lower()
        if not freq.word_is_common(w):
            continue
        fs = extract_forms(obj)
        if fs:
            forms_of[w].update(fs)
    return forms_of


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--norvig", default="count_1w.txt")
    ap.add_argument("--subs", default="en_full.txt")
    ap.add_argument("--review-queue", default="review_queue.jsonl")
    args = ap.parse_args()

    src_path = Path(args.src)
    dst_path = Path(args.dst)
    if not src_path.exists():
        print(f"ERROR: source file not found: {src_path}", file=sys.stderr)
        sys.exit(1)
    for freq_path in (args.norvig, args.subs):
        if not Path(freq_path).exists():
            print(f"ERROR: frequency list not found: {freq_path}", file=sys.stderr)
            sys.exit(1)
    if dst_path.exists():
        dst_path.unlink()

    print("Loading frequency lists...")
    freq = FrequencyFilter(args.norvig, args.subs)

    print("Pass 1: collecting inflected forms of common words...")
    forms_of = collect_forms_map(src_path, freq)
    print(f"  {len(forms_of):,} common lemmas with forms")

    conn = sqlite3.connect(dst_path)
    cur = conn.cursor()
    cur.execute("PRAGMA journal_mode=OFF")
    cur.execute("PRAGMA synchronous=OFF")
    create_schema(cur)

    total_in = 0
    total_senses = 0
    total_forms = 0
    dropped_rare = 0
    dropped_stubs = 0
    next_id = 1
    lemma_sense_count: dict[str, int] = defaultdict(int)
    review_rows: list[dict] = []

    entry_batch: list[tuple[int, str, str, str, str]] = []
    form_batch: list[tuple[str, str]] = []
    insert_entry = "INSERT INTO entries (id, lemma, pos, definition, example) VALUES (?, ?, ?, ?, ?)"
    insert_form = "INSERT INTO forms (form, lemma) VALUES (?, ?)"

    def flush() -> None:
        if entry_batch:
            cur.executemany(insert_entry, entry_batch)
            entry_batch.clear()
        if form_batch:
            cur.executemany(insert_form, form_batch)
            form_batch.clear()

    print("Pass 2: building dictionary...")
    if True:
        for obj in iter_dump(src_path, "pass 2"):
            total_in += 1
            word = obj.get("word", "")
            if not isinstance(word, str) or not LEMMA_OK.match(word):
                continue
            pos = obj.get("pos", "")
            if not isinstance(pos, str) or not pos or pos.lower() in DROP_POS:
                continue

            lemma = word.lower()
            if not freq.lemma_is_common(lemma):
                dropped_rare += 1
                continue

            multiword = (" " in lemma) or ("-" in lemma)

            candidates: list[tuple[str, str, str | None]] = []  # gloss, example, flag
            overlong: list[tuple[str, str, str | None]] = []
            for sense in obj.get("senses") or []:
                if sense_has_bad_tag(sense):
                    continue
                glosses = sense.get("glosses") or []
                if not glosses:
                    continue
                gloss = strip_grammar_label(clean_gloss(glosses[-1]))
                if gloss_is_droppable(gloss):
                    if MAX_GLOSS_LEN < len(gloss) <= OVERLONG_RESCUE_MAX and not gloss_content_droppable(gloss):
                        overlong.append((gloss, pick_example(sense), "complex"))
                    continue
                echo = self_ref_token(lemma, gloss, forms_of)
                if not multiword and echo and STUB_RE.match(gloss):
                    flag = "stub"
                elif multiword and is_circular_multiword(lemma, gloss):
                    flag = "circular"
                elif not multiword and echo:
                    flag = "self_ref"
                elif is_complex(gloss):
                    flag = "complex"
                else:
                    flag = None
                candidates.append((gloss, pick_example(sense), flag))

            real = [c for c in candidates if c[2] != "stub"][:MAX_SENSES_PER_ENTRY]
            if real:
                kept = real
                dropped_stubs += sum(1 for c in candidates if c[2] == "stub")
            elif candidates:
                kept = [candidates[0]]
            elif overlong:
                kept = [overlong[0]]
            else:
                kept = []

            for gloss, example, flag in kept:
                entry_batch.append((next_id, lemma, pos, gloss, example))
                lemma_sense_count[lemma] += 1
                if flag:
                    review_rows.append({
                        "id": next_id, "lemma": lemma, "pos": pos,
                        "definition": gloss, "flag": flag,
                    })
                next_id += 1
                total_senses += 1

            if kept:
                for form in extract_forms(obj):
                    if form != lemma:
                        form_batch.append((form, lemma))
                        total_forms += 1

            if len(entry_batch) >= 5000 or len(form_batch) >= 5000:
                flush()

    flush()

    print("Creating indexes...")
    create_indexes(cur)
    conn.commit()
    conn.close()

    for row in review_rows:
        row["only_sense"] = lemma_sense_count[row["lemma"]] == 1
    write_jsonl(args.review_queue, review_rows)

    size_mb = dst_path.stat().st_size / (1024 * 1024)
    print(f"Done. Read {total_in:,} lines.")
    print(f"Kept {total_senses:,} senses across {len(lemma_sense_count):,} lemmas; {total_forms:,} forms.")
    print(f"Dropped: {dropped_rare:,} rare entries, {dropped_stubs:,} redundant stubs.")
    print(f"Review queue: {len(review_rows):,} senses -> {args.review_queue}")
    print(f"Output: {dst_path} — {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
