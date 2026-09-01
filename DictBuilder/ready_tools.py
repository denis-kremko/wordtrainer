"""Toolkit for building ready_groups v2 lists against the real dictionary.

Replicates the app's boundSense exactly: entries ordered by (rank, id),
filtered to the effective POS when that filter is non-empty, then the first
hint-matching definition, else the first entry.

Commands (workdir layout: /tmp/ready_v2/work/<id>/, finals in /tmp/ready_v2/final/):
  probe <id>        candidates.json -> probe.json (existence + numbered defs)
  finalize <id>     picks.json + seeds -> final/<id>.json (+ report on stdout)
  render <id>       print every final word with its bound definition + alternatives
  apply_audit <id>  audit.json (drop / re-pick) -> rewrite final/<id>.json
  assemble          all finals -> ready_groups.json v2 on stdout path
"""
import json, os, re, sqlite3, sys

DB = '/tmp/dictionary-v2.sqlite'
ROOT = '/tmp/ready_v2'
SPEC = json.load(open(f'{ROOT}/spec.json'))
STOP = {'the', 'and', 'with', 'that', 'this', 'from', 'for', 'into', 'onto',
        'over', 'under', 'which', 'who', 'whom', 'whose', 'when', 'where',
        'not', 'one', 'any', 'some', 'such', 'etc', 'also', 'very'}

def spec_of(list_id):
    for s in SPEC['lists']:
        if s['id'] == list_id:
            return s
    sys.exit(f'unknown list id {list_id}')

def normalize(w):
    return w.lower().strip()

_conn = None
def defs_for(lemma, eff_pos):
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(DB)
    rows = _conn.execute(
        'SELECT pos, definition FROM entries WHERE lemma = ? ORDER BY rank, id',
        (normalize(lemma),)).fetchall()
    if eff_pos:
        filtered = [r for r in rows if r[0] == eff_pos]
        if filtered:
            rows = filtered
    return rows

def bound_index(defs, hint):
    if not hint:
        return 0 if defs else -1
    for i, (_, d) in enumerate(defs):
        dl = d.lower()
        if any(h in dl for h in hint):
            return i
    return 0 if defs else -1

def derive_hint(defs, pick):
    if pick == 0:
        return None
    picked = defs[pick][1].lower()
    earlier = [d.lower() for _, d in defs[:pick]]
    tokens = sorted(set(re.findall(r'[a-z]{3,}', picked)) - STOP, key=len, reverse=True)
    for tok in tokens:
        if all(tok not in e for e in earlier):
            return [tok]
    for pair in re.findall(r'(?=([a-z]{3,} [a-z]{3,}))', picked):
        if all(pair not in e for e in earlier):
            return [pair]
    for i, tok1 in enumerate(tokens):
        for tok2 in tokens[i + 1:]:
            if all(tok1 not in e or tok2 not in e for e in earlier):
                return None  # two-key AND is not expressible: hints are OR
    return None

def load_words(path):
    data = json.load(open(path))
    return data['words'] if isinstance(data, dict) else data

def cmd_probe(list_id):
    s = spec_of(list_id)
    wd = f'{ROOT}/work/{list_id}'
    cands = load_words(f'{wd}/candidates.json')
    seeds = {normalize(w['w']) for w in s['seeds']}
    out = []
    for c in cands:
        w = normalize(c['w'])
        eff = c.get('pos') or s.get('pos')
        defs = defs_for(w, eff)
        out.append({
            'w': w, 'pos': c.get('pos'), 'sense': c.get('sense'),
            'duplicate_of_seed': w in seeds,
            'found': bool(defs),
            'defs': [{'i': i, 'pos': p, 'd': d} for i, (p, d) in enumerate(defs[:12])],
        })
    json.dump(out, open(f'{wd}/probe.json', 'w'), indent=1, ensure_ascii=False)
    print(json.dumps({'candidates': len(out),
                      'found': sum(1 for o in out if o['found']),
                      'seed_duplicates': sum(1 for o in out if o['duplicate_of_seed'])}))

def cmd_finalize(list_id):
    s = spec_of(list_id)
    wd = f'{ROOT}/work/{list_id}'
    picks_path = f'{wd}/picks.json'
    picks = load_words(picks_path) if os.path.exists(picks_path) else []
    used = {normalize(w['w']) for w in s['seeds']}
    words, dropped = list(s['seeds']), []
    for p in picks:
        w = normalize(p['w'])
        if w in used:
            dropped.append({'w': w, 'why': 'duplicate'})
            continue
        eff = p.get('pos') or s.get('pos')
        defs = defs_for(w, eff)
        pick = p.get('pick', 0)
        if not defs or pick < 0 or pick >= len(defs):
            dropped.append({'w': w, 'why': 'not_found_or_bad_pick'})
            continue
        hint = derive_hint(defs, pick)
        if pick > 0 and hint is None:
            dropped.append({'w': w, 'why': 'no_distinguishing_hint'})
            continue
        if bound_index(defs, hint) != pick:
            dropped.append({'w': w, 'why': 'hint_rebind_mismatch'})
            continue
        entry = {'w': w}
        if p.get('pos') and p['pos'] != s.get('pos'):
            entry['pos'] = p['pos']
        if hint:
            entry['hint'] = hint
        used.add(w)
        words.append(entry)
    final = {'id': s['id'], 'name': s['name'], 'icon': s['icon'],
             'description': s['description'], 'words': words}
    if s.get('pos'):
        final['pos'] = s['pos']
    os.makedirs(f'{ROOT}/final', exist_ok=True)
    json.dump(final, open(f'{ROOT}/final/{list_id}.json', 'w'), indent=1, ensure_ascii=False)
    print(json.dumps({'count': len(words), 'new': len(words) - len(s['seeds']),
                      'seeds': len(s['seeds']), 'dropped': dropped}))

def cmd_render(list_id):
    final = json.load(open(f'{ROOT}/final/{list_id}.json'))
    print(f"# {final['name']} — {final['description']}")
    for i, w in enumerate(final['words']):
        eff = w.get('pos') or final.get('pos')
        defs = defs_for(w['w'], eff)
        b = bound_index(defs, w.get('hint'))
        if b < 0:
            print(f"{i:3} {w['w']} [{eff or 'any'}] !! NOT FOUND IN DICTIONARY")
            continue
        print(f"{i:3} {w['w']} [{defs[b][0]}]{' hint=' + str(w['hint']) if w.get('hint') else ''}"
              f" -> {defs[b][1]}")
        for j, (p, d) in enumerate(defs[:7]):
            if j != b:
                print(f"      alt {j} [{p}]: {d}")

def cmd_apply_audit(list_id):
    wd = f'{ROOT}/work/{list_id}'
    final_path = f'{ROOT}/final/{list_id}.json'
    final = json.load(open(final_path))
    audit = json.load(open(f'{wd}/audit.json'))
    by_w = {normalize(w['w']): w for w in final['words']}
    report = []
    for pr in audit.get('problems', []):
        w = normalize(pr['w'])
        entry = by_w.get(w)
        if entry is None:
            report.append({'w': w, 'did': 'skip_unknown'})
            continue
        if pr['action'] == 'drop':
            final['words'].remove(entry)
            by_w.pop(w)
            report.append({'w': w, 'did': 'dropped'})
        elif pr['action'] == 'pick':
            eff = entry.get('pos') or final.get('pos')
            defs = defs_for(w, eff)
            pick = pr.get('pick', -1)
            if pick < 0 or pick >= len(defs):
                report.append({'w': w, 'did': 'bad_pick_index'})
                continue
            hint = derive_hint(defs, pick)
            if pick > 0 and (hint is None or bound_index(defs, hint) != pick):
                final['words'].remove(entry)
                by_w.pop(w)
                report.append({'w': w, 'did': 'dropped_no_hint'})
                continue
            entry.pop('hint', None)
            if hint:
                entry['hint'] = hint
            report.append({'w': w, 'did': 'rehinted'})
    json.dump(final, open(final_path, 'w'), indent=1, ensure_ascii=False)
    print(json.dumps({'count': len(final['words']), 'applied': report}))

LEVELS = {'a': ('A1–A2', 'Beginner'), 'b': ('B1–B2', 'Independent'), 'c': ('C1–C2', 'Proficient')}
THEMES = [
    ('phrasal-verbs', 'Phrasal Verbs', 'arrow.triangle.branch',
     'From first steps to the ones that make you sound native.',
     ['a-phrasal-basics', 'b-phrasal-essentials', 'c-phrasal-advanced']),
    ('idioms', 'Everyday Idioms', 'quote.bubble',
     'Idioms natives actually use, from small talk to the office.',
     ['c-idioms-everyday']),
    ('emotions-character', 'Emotions & Character', 'face.smiling',
     'Words for feelings and personality, from happy to magnanimous.',
     ['a-feelings-character', 'b-emotions-character', 'c-emotions-character']),
    ('money-finance', 'Money & Finance', 'chart.line.uptrend.xyaxis',
     'From paying at the till to reading the financial press.',
     ['a-money-shopping', 'b-finance-money', 'c-finance-economics']),
    ('work-business', 'Work & Business', 'briefcase',
     'Jobs, offices, and boardrooms.',
     ['a-work-jobs', 'b-business-office', 'c-business-strategy']),
    ('law-contracts', 'Law & Contracts', 'text.book.closed',
     'Contracts, courts, and the fine print.',
     ['b-legal-contracts', 'c-law-courts']),
    ('tech-programming', 'Tech & Programming', 'chevron.left.forwardslash.chevron.right',
     'From everyday computing to engineering tradeoffs.',
     ['a-computers-internet', 'b-tech-programming', 'c-tech-engineering']),
    ('health-body', 'Health & Body', 'cross.case',
     'The body, the doctor, and the clinic.',
     ['a-body-health', 'b-health-body', 'c-medicine-anatomy']),
    ('cooking-kitchen', 'Cooking & Kitchen', 'frying.pan',
     'From boiling an egg to braising like a chef.',
     ['a-cooking-kitchen', 'b-cooking-kitchen', 'c-cooking-gastronomy']),
    ('travel', 'Travel & Airport', 'airplane',
     'Holidays, airports, and getting around a foreign country.',
     ['a-travel-holidays', 'b-travel-airport']),
    ('cars-transport', 'Cars & Transport', 'car',
     'Streets, vehicles, and life behind the wheel.',
     ['a-transport-streets', 'b-cars-driving']),
    ('weather-nature', 'Weather & Nature', 'cloud.bolt.rain',
     'From small talk about rain to precise words for landscapes.',
     ['a-weather-nature', 'b-weather-nature', 'c-nature-environment']),
    ('animals-wildlife', 'Animals & Wildlife', 'bird',
     'Pets, farm animals, and documentary vocabulary.',
     ['a-animals-birds', 'b-animals-birds', 'c-wildlife-zoology']),
    ('fruits-berries', 'Fruits & Berries', 'leaf',
     'The fruit bowl, from apples to fruit anatomy.',
     ['a-fruits-berries', 'b-fruits-berries']),
    ('vegetables-herbs', 'Vegetables & Herbs', 'carrot',
     'Shopping-list basics to farmers-market vocabulary.',
     ['a-vegetables-herbs', 'b-vegetables-herbs']),
    ('home-furniture', 'Home & Furniture', 'sofa',
     'Rooms, fixtures, and furniture.',
     ['a-home-furniture', 'b-home-furniture']),
    ('clothes-fashion', 'Clothes & Fashion', 'tshirt',
     'What you wear: garments, fabrics, and cuts.',
     ['a-clothes-fashion', 'b-clothes-fashion']),
    ('sports-fitness', 'Sports & Fitness', 'figure.run',
     'Playing, training, and game day.',
     ['a-sports-games', 'b-sports-fitness']),
    ('fishing-outdoors', 'Fishing & Outdoors', 'figure.fishing',
     'Rods, reels, camps, and trails.',
     ['b-fishing-outdoors']),
    ('sci-fi-space', 'Sci-Fi & Space', 'sparkles',
     'Spaceships, aliens, and the vocabulary of the future.',
     ['b-sci-fi-space', 'c-sci-fi-space']),
    ('movies-tv', 'Movies & TV', 'film',
     'From buying a ticket to arguing about the ending.',
     ['a-movies-tv', 'b-movies-tv', 'c-movies-tv']),
    ('games-gaming', 'Games & Gaming', 'gamecontroller',
     'Board games, video games, and play.',
     ['a-games-gaming', 'b-games-gaming', 'c-games-gaming']),
    ('medieval-knights', 'Medieval & Knights', 'shield',
     'Castles, crowns, and the age of chivalry.',
     ['b-medieval-knights', 'c-medieval-knights']),
    ('verbs-motion', 'Verbs: Motion & Action', 'figure.walk.motion',
     'How bodies and things move, from walk to hurl.',
     ['a-verbs-motion', 'b-verbs-motion', 'c-verbs-motion']),
    ('verbs-thinking', 'Verbs: Thinking & Feeling', 'brain.head.profile',
     'Verbs for what happens in your head.',
     ['a-verbs-thinking', 'b-verbs-thinking', 'c-verbs-thinking']),
    ('adjectives-things', 'Adjectives: Look & Feel', 'cube',
     'Size, shape, and texture words for things.',
     ['a-adjectives-things', 'b-adjectives-things', 'c-adjectives-things']),
    ('adjectives-people', 'Adjectives: People & Looks', 'person.crop.circle',
     'Describing how people look and carry themselves.',
     ['a-adjectives-people', 'b-adjectives-people', 'c-adjectives-people']),
    ('music-instruments', 'Music & Instruments', 'music.note',
     'From humming a tune to reading a score.',
     ['a-music-instruments', 'b-music-instruments', 'c-music-instruments']),
    ('art-museums', 'Art & Museums', 'paintpalette',
     'Galleries, canvases, and how to talk about them.',
     ['b-art-museums', 'c-art-museums']),
    ('books-writing', 'Books & Writing', 'book.closed',
     'Reading, writing, and the words for both.',
     ['a-books-writing', 'b-books-writing', 'c-books-writing']),
    ('crime-detectives', 'Crime & Detectives', 'magnifyingglass',
     'Clues, suspects, and whodunits.',
     ['b-crime-detectives', 'c-crime-detectives']),
    ('war-military', 'War & Military', 'shield.lefthalf.filled',
     'From toy soldiers to war reporting.',
     ['b-war-military', 'c-war-military']),
    ('science-lab', 'Science & the Lab', 'testtube.2',
     'Experiments, theories, and lab benches.',
     ['b-science-lab', 'c-science-lab']),
    ('city-architecture', 'City & Architecture', 'building.2',
     'Streets, buildings, and how cities are made.',
     ['b-city-architecture', 'c-city-architecture']),
    ('sea-sailing', 'Sea & Sailing', 'sailboat',
     'Harbours, decks, and open water.',
     ['b-sea-sailing', 'c-sea-sailing']),
    ('myths-fantasy', 'Myths & Fantasy', 'wand.and.stars',
     'Dragons, spells, and old gods.',
     ['b-myths-fantasy', 'c-myths-fantasy']),
    ('school-university', 'School & University', 'backpack',
     'From the classroom to the thesis defence.',
     ['a-school-university', 'b-school-university', 'c-school-university']),
    ('love-relationships', 'Love & Relationships', 'heart',
     'From first crush to long marriage.',
     ['a-love-relationships', 'b-love-relationships', 'c-love-relationships']),
    ('time-routine', 'Time & Daily Routine', 'clock',
     'Mornings, deadlines, and the shape of a day.',
     ['a-time-routine', 'b-time-routine', 'c-time-routine']),
]

def rows_for(lemma, eff_pos):
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(DB)
    rows = _conn.execute(
        'SELECT id, pos, definition FROM entries WHERE lemma = ? ORDER BY rank, id',
        (normalize(lemma),)).fetchall()
    if eff_pos:
        filtered = [r for r in rows if r[1] == eff_pos]
        if filtered:
            rows = filtered
    return rows

def cmd_snapshot_bound(out_path):
    import glob
    snap = {}
    for f in sorted(glob.glob(f'{ROOT}/final/*.json')):
        final = json.load(open(f))
        per = {}
        for w in final['words']:
            eff = w.get('pos') or final.get('pos')
            rows = rows_for(w['w'], eff)
            defs = [(r[1], r[2]) for r in rows]
            b = bound_index(defs, w.get('hint'))
            if b >= 0:
                per[w['w']] = rows[b][0]
        snap[final['id']] = per
    json.dump(snap, open(out_path, 'w'))
    print('snapshot:', sum(len(v) for v in snap.values()), 'bound senses ->', out_path)

def cmd_rebind(snapshot_path):
    import glob
    snap = json.load(open(snapshot_path))
    ok = rehinted = lost = underivable = 0
    for f in sorted(glob.glob(f'{ROOT}/final/*.json')):
        final = json.load(open(f))
        per = snap.get(final['id'], {})
        changed = False
        for w in final['words']:
            target = per.get(w['w'])
            if target is None:
                continue
            eff = w.get('pos') or final.get('pos')
            rows = rows_for(w['w'], eff)
            ids = [r[0] for r in rows]
            defs = [(r[1], r[2]) for r in rows]
            if target not in ids:
                lost += 1
                print(f"LOST {final['id']}: {w['w']} (sense {target} deleted)")
                if w.pop('hint', None) is not None:
                    changed = True
                continue
            pick = ids.index(target)
            if bound_index(defs, w.get('hint')) == pick:
                ok += 1
                continue
            hint = derive_hint(defs, pick)
            if pick > 0 and hint is None:
                underivable += 1
                print(f"UNDERIVABLE {final['id']}: {w['w']} -> sense {target}")
                continue
            w.pop('hint', None)
            if hint:
                w['hint'] = hint
            rehinted += 1
            changed = True
        if changed:
            json.dump(final, open(f, 'w'), indent=1, ensure_ascii=False)
    print(json.dumps({'ok': ok, 'rehinted': rehinted, 'lost': lost, 'underivable': underivable}))

def cmd_assemble(out_path):
    themes = []
    total = 0
    used = set()
    for tid, name, icon, desc, level_ids in THEMES:
        levels = []
        for lid in level_ids:
            used.add(lid)
            g = json.load(open(f'{ROOT}/final/{lid}.json'))
            level, subtitle = LEVELS[lid.split('-')[0]]
            n = len(g['words'])
            total += n
            flag = '' if 40 <= n <= 60 else '  <-- OUT OF 40-60'
            print(f'{lid:24} {n:3}{flag}')
            entry = {'id': lid, 'level': level, 'levelSubtitle': subtitle,
                     'name': f'{name} · {level}', 'icon': icon,
                     'description': g['description'], 'words': g['words']}
            if g.get('pos'):
                entry['pos'] = g['pos']
            levels.append(entry)
        themes.append({'id': tid, 'name': name, 'icon': icon,
                       'description': desc, 'levels': levels})
    missing = {s['id'] for s in SPEC['lists']} - used
    if missing:
        print('!! lists not mapped to any theme:', sorted(missing))
    json.dump({'version': 2, 'themes': themes}, open(out_path, 'w'),
              indent=1, ensure_ascii=False)
    print(f'themes: {len(themes)}, total words: {total} -> {out_path}')

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'probe':
        cmd_probe(sys.argv[2])
    elif cmd == 'finalize':
        cmd_finalize(sys.argv[2])
    elif cmd == 'render':
        cmd_render(sys.argv[2])
    elif cmd == 'apply_audit':
        cmd_apply_audit(sys.argv[2])
    elif cmd == 'snapshot_bound':
        cmd_snapshot_bound(sys.argv[2])
    elif cmd == 'rebind':
        cmd_rebind(sys.argv[2])
    elif cmd == 'assemble':
        cmd_assemble(sys.argv[2])
    else:
        sys.exit('unknown command')
