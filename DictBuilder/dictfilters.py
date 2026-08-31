"""Shared filtering heuristics and helpers for the dictionary build pipeline."""

from __future__ import annotations
import json
import re
import sqlite3
from collections import defaultdict
from functools import lru_cache

# Calibrated: keeps perspicacious/sesquipedalian/pulchritude, drops coom/thole/anent.
NORVIG_MAX_RANK = 100_000
SUBS_MAX_RANK = 250_000

MIN_GLOSS_LEN = 8
MAX_GLOSS_LEN = 200

COMPLEX_LEN = 150
COMPLEX_SEMICOLONS = 2
COMPLEX_COMMA_LEN = 120
COMPLEX_COMMAS = 3

CIRCULAR_MAX_LEN = 45

STOPWORDS = frozenset("""
a an the to of in on at by for with up down out off over under about into onto
from as or and not no one it be is are was were been being do does did have has
had i you he she we they them him her his its their your my our me us so if
than then that this these those there here when where while who whom whose
which what how why all any some such very too also just but yet nor neither
either each every both few more most other another same own s t
""".split())

TOKEN_RE = re.compile(r"[a-z']+")

# The FIRST word must be an unambiguous morphology term; generic connectors
# (the, form, case, standard) only mid-phrase, else 'Standard of living.' dies.
_MORPH_COMMON = (
    "present", "past", "simple", "participle", "gerund", "third-person",
    "second-person", "first-person", "singular", "plural", "indicative",
    "subjunctive", "imperative", "comparative", "superlative", "attributive",
    "nominative", "accusative", "genitive", "dative", "feminine", "masculine",
    "neuter", "diminutive", "augmentative", "inflection", "romanization",
    "clipping", "contraction", "abbreviation", "initialism", "acronym",
    "synonym", "misspelling", "obsolete", "archaic", "dated", "nonstandard",
    "alternative", "alternate", "elongated", "intensified", "emphatic",
)
_MORPH_MID_ONLY = (
    "and", "or", "the", "tense", "form", "spelling", "standard", "rare",
    "informal", "eye", "dialect", "pronunciation", "letter-case", "case",
    "typography", "combining", "humorous",
)
_MORPH_HEAD_ONLY = ("eye dialect",)


def _alternation(terms: tuple[str, ...]) -> str:
    return "(?:" + "|".join(terms) + ")"


_INFL = _alternation(_MORPH_COMMON + _MORPH_MID_ONLY)
_INFL_HEAD = _alternation(_MORPH_HEAD_ONLY + _MORPH_COMMON)
CROSS_REF_RE = re.compile(rf"^{_INFL_HEAD}(?: {_INFL})* of [a-zA-Z' -]+[.!?]?$", re.I)

STUB_RE = re.compile(
    r"^(in a[n]? [a-z-]+ (manner|way|fashion)[.;]?$"
    r"|one who [a-z' -]+[.;]?$"
    r"|the (quality|state|act|property|process|condition) of (being )?[a-z' -]+[.;]?$"
    r"|(someone|somebody|a person) who [a-z' -]+[.;]?$)",
    re.I,
)

GRAMMAR_LABELS = frozenset("""
transitive intransitive ambitransitive ditransitive reflexive copulative auxiliary
impersonal ergative stative countable uncountable usually chiefly often also
figurative figuratively literally literal idiomatic idiomatically colloquial
colloquially informal formal slang euphemistic intransitively transitively
""".split()) | {"by extension"}

_LEADING_PAREN_RE = re.compile(r"^\s*\(([^()]{1,80})\)\s*")


def leading_paren_labels(gloss: str) -> tuple[frozenset[str] | None, str]:
    """(labels inside a leading parenthetical, rest of the gloss) or (None, gloss)."""
    m = _LEADING_PAREN_RE.match(gloss)
    if not m:
        return None, gloss
    labels = frozenset(p.strip().lower() for p in m.group(1).split(","))
    return labels, gloss[m.end():].strip()


def strip_grammar_label(gloss: str) -> str:
    labels, rest = leading_paren_labels(gloss)
    if labels is not None and labels <= GRAMMAR_LABELS:
        if rest:
            return rest[0].upper() + rest[1:]
        return ""  # the gloss was ONLY a label — empty lets the length filter drop it
    return gloss


@lru_cache(maxsize=1 << 20)
def content_words(lemma: str) -> tuple[str, ...]:
    return tuple(w for w in TOKEN_RE.findall(lemma.lower()) if w not in STOPWORDS and len(w) >= 3)


@lru_cache(maxsize=1 << 20)
def stem_candidates(w: str) -> frozenset[str]:
    """Crude suffix-stripping: enough to link quick/quickly, come/coming, run/running."""
    out = {w}
    rules = [
        ("ies", "y"), ("ied", "y"),
        ("ings", ""), ("ing", ""), ("ments", ""), ("ment", ""),
        ("ness", ""), ("ers", ""), ("er", ""), ("est", ""),
        ("edly", ""), ("ed", ""), ("ly", ""), ("es", ""), ("s", ""), ("d", ""),
    ]
    for suf, repl in rules:
        if w.endswith(suf) and len(w) - len(suf) + len(repl) >= 3:
            stem = w[: len(w) - len(suf)] + repl
            out.add(stem)
            out.add(stem + "e")            # com -> come, lov -> love
            if len(stem) >= 4 and stem[-1] == stem[-2]:
                out.add(stem[:-1])         # runn -> run
    return frozenset(out)


def self_ref_token(lemma: str, definition: str, forms_of: dict[str, set[str]]) -> str | None:
    """Return the gloss token that echoes the headword, or None."""
    words = content_words(lemma)
    if not words:
        return None
    tokens = set(TOKEN_RE.findall(definition.lower()))
    for w in words:
        if w in tokens:
            return w
        wf = forms_of.get(w) or ()
        for t in tokens:
            if t in wf:
                return t
        wc = stem_candidates(w)
        for t in tokens:
            if len(t) >= 3 and (t in wc or bool(stem_candidates(t) & wc)):
                return t
    return None


def is_derivational_stub(lemma: str, gloss: str, forms_of: dict[str, set[str]]) -> bool:
    """Boilerplate gloss that merely re-derives the headword ("abandoner: One who
    abandons."). Requires BOTH the stub shape and a root echo — shape alone also
    matches real definitions ("theft: The act of stealing.")."""
    return bool(STUB_RE.match(gloss)) and self_ref_token(lemma, gloss, forms_of) is not None


def is_circular_multiword(lemma: str, definition: str) -> bool:
    """Short multiword gloss that is basically just the headword's root again."""
    if len(definition) >= CIRCULAR_MAX_LEN:
        return False
    roots = set(content_words(lemma))
    if not roots:
        return False
    toks = [
        t for t in TOKEN_RE.findall(definition.lower())
        if t not in ("to", "a", "an", "the", "or", "of", "in", "on", "and")
    ]
    rest = [
        t for t in toks
        if not any(t.startswith(w[:4]) or (len(t) >= 4 and w.startswith(t[:4])) for w in roots)
    ]
    return len(rest) <= 1


def is_complex(definition: str) -> bool:
    if len(definition) > COMPLEX_LEN:
        return True
    if definition.count(";") >= COMPLEX_SEMICOLONS:
        return True
    if len(definition) > COMPLEX_COMMA_LEN and definition.count(",") >= COMPLEX_COMMAS:
        return True
    return False


def load_ranks(path: str, sep: str, max_rank: int) -> dict[str, int]:
    ranks: dict[str, int] = {}
    with open(path, encoding="utf-8", errors="ignore") as f:
        for rank, line in enumerate(f, 1):
            if rank > max_rank:
                break
            w = line.split(sep)[0].strip().lower()
            if w and w not in ranks:
                ranks[w] = rank
    return ranks


class FrequencyFilter:
    def __init__(self, norvig_path: str, subs_path: str):
        self.norvig = load_ranks(norvig_path, "\t", NORVIG_MAX_RANK)
        self.subs = load_ranks(subs_path, " ", SUBS_MAX_RANK)

    def word_is_common(self, w: str) -> bool:
        return w in self.norvig or w in self.subs

    def lemma_is_common(self, lemma: str) -> bool:
        parts = content_words(lemma)
        return (not parts) or all(self.word_is_common(p) for p in parts)


def build_forms_map(db_path: str, wanted: set[str] | None = None) -> dict[str, set[str]]:
    """lemma -> its inflected forms; `wanted` keeps only those lemmas (saves
    materializing the whole forms table when the caller needs a few words)."""
    conn = sqlite3.connect(db_path)
    forms_of: dict[str, set[str]] = defaultdict(set)
    for form, lemma in conn.execute("SELECT form, lemma FROM forms"):
        if wanted is None or lemma in wanted:
            forms_of[lemma].add(form)
    conn.close()
    return forms_of


def create_schema(cur: sqlite3.Cursor) -> None:
    cur.execute("""
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            lemma TEXT NOT NULL,
            pos TEXT NOT NULL,
            definition TEXT NOT NULL,
            example TEXT,
            rank INTEGER NOT NULL DEFAULT 0
        )
    """)
    cur.execute("CREATE TABLE forms (form TEXT NOT NULL, lemma TEXT NOT NULL)")


def create_indexes(cur: sqlite3.Cursor) -> None:
    cur.execute("CREATE INDEX idx_entries_lemma ON entries(lemma)")
    cur.execute("CREATE INDEX idx_forms_form ON forms(form)")


def write_jsonl(path, rows) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
