#!/usr/bin/env python3
"""
Build the small bundled demo dictionary (WordAce/Resources/dictionary.sqlite).

The demo DB ships inside the app bundle so Xcode previews and first-launch
fallback work without downloading the full dictionary. Same schema as
build_dict.py output:

    entries(id INTEGER PK, lemma TEXT, pos TEXT, definition TEXT, example TEXT)
    forms(form TEXT, lemma TEXT)

Usage:
    python3 build_demo_dict.py ../WordAce/Resources/dictionary.sqlite
"""

from __future__ import annotations
import sqlite3
import sys
from pathlib import Path

from dictfilters import create_indexes, create_schema

ENTRIES: list[tuple[str, str, str, str]] = [
    ("run", "verb", "To move swiftly on foot so that both feet leave the ground during each stride.",
     "She runs five kilometres every morning."),
    ("run", "verb", "To operate or manage something, such as a business or a machine.",
     "He runs a small bakery downtown."),
    ("run", "noun", "An act or instance of running; a jog.",
     "Let's go for a run before breakfast."),
    ("come", "verb", "To move toward the speaker or a specified place; to arrive.",
     "Come here and look at this."),
    ("come", "verb", "To happen or occur in due course.",
     "Spring came early this year."),
    ("go", "verb", "To move or travel from one place to another, away from the speaker.",
     "We go to the mountains every winter."),
    ("set", "verb", "To put something in a specified place or position.",
     "She set the vase on the table."),
    ("set", "noun", "A group of related things that belong together.",
     "He bought a set of kitchen knives."),
    ("light", "noun", "The natural agent that stimulates sight and makes things visible.",
     "The light of the moon filled the room."),
    ("light", "adjective", "Of little weight; not heavy.",
     "The suitcase is light enough to carry."),
    ("book", "noun", "A written or printed work consisting of pages bound together.",
     "She reads one book a week."),
    ("book", "verb", "To reserve a place, ticket, or service in advance.",
     "We booked a table for two at eight."),
    ("mouse", "noun", "A small rodent with a pointed snout and a long thin tail.",
     "A mouse darted across the kitchen floor."),
    ("mouse", "noun", "A hand-held device used to move a pointer on a computer screen.",
     "Click the left button of the mouse."),
    ("good", "adjective", "Having the required qualities; of a high standard.",
     "That was a good meal."),
    ("meticulous", "adjective", "Showing great attention to detail; very careful and precise.",
     "He kept meticulous records of every expense."),
    ("resilient", "adjective", "Able to recover quickly from difficult conditions.",
     "Children are often remarkably resilient."),
    ("ubiquitous", "adjective", "Present, appearing, or found everywhere.",
     "Smartphones have become ubiquitous in daily life."),

    ("come up with", "verb", "To think of or produce an idea, plan, or solution.",
     "She came up with a brilliant solution."),
    ("put up with", "verb", "To tolerate or endure something unpleasant without complaining.",
     "I don't know how you put up with that noise."),
    ("break down", "verb", "To stop functioning, especially of a machine or vehicle.",
     "The car broke down on the motorway."),
    ("give up", "verb", "To stop trying; to abandon an effort or habit.",
     "Never give up on your dreams."),
    ("look forward to", "verb", "To await something eagerly with pleasure.",
     "I look forward to hearing from you."),
    ("run into", "verb", "To meet someone unexpectedly.",
     "I ran into an old friend at the station."),
    ("take off", "verb", "Of an aircraft: to leave the ground and begin to fly.",
     "The plane took off on time."),
    ("take off", "verb", "To remove an item of clothing.",
     "Take off your coat and stay a while."),

    ("break a leg", "phrase", "Used to wish a performer good luck before a performance.",
     "You're on in five minutes — break a leg!"),
    ("piece of cake", "phrase", "Something very easy to do.",
     "The exam was a piece of cake."),
    ("hit the books", "phrase", "To begin studying seriously.",
     "Finals are next week, so it's time to hit the books."),
]

FORMS: list[tuple[str, str]] = [
    ("ran", "run"), ("runs", "run"), ("running", "run"),
    ("came", "come"), ("comes", "come"), ("coming", "come"),
    ("went", "go"), ("goes", "go"), ("going", "go"), ("gone", "go"),
    ("sets", "set"), ("setting", "set"),
    ("lit", "light"), ("lighter", "light"), ("lightest", "light"),
    ("books", "book"), ("booked", "book"), ("booking", "book"),
    ("mice", "mouse"),
    ("better", "good"), ("best", "good"),
    ("gave up", "give up"), ("given up", "give up"),
    ("broke down", "break down"), ("broken down", "break down"),
    ("came up with", "come up with"),
    ("ran into", "run into"),
    ("took off", "take off"), ("taken off", "take off"),
]


def main(dst: str) -> None:
    dst_path = Path(dst)
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    if dst_path.exists():
        dst_path.unlink()

    conn = sqlite3.connect(dst_path)
    cur = conn.cursor()
    create_schema(cur)
    cur.executemany("INSERT INTO entries (lemma, pos, definition, example) VALUES (?, ?, ?, ?)", ENTRIES)
    cur.executemany("INSERT INTO forms (form, lemma) VALUES (?, ?)", FORMS)
    create_indexes(cur)
    conn.commit()
    conn.close()

    size_kb = dst_path.stat().st_size / 1024
    print(f"Demo dictionary: {len(ENTRIES)} senses, {len(FORMS)} forms -> {dst_path} ({size_kb:.0f} KB)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: build_demo_dict.py <output.sqlite>")
        sys.exit(1)
    main(sys.argv[1])
