export const meta = {
  name: 'ready-new-themes',
  description: 'Build new Library theme lists: candidates, sense picks, or audit — one agent per list',
  phases: [{ title: 'Lists' }],
}

const CANDIDATES = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    words: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          w: { type: 'string' },
          pos: { type: 'string' },
        },
        required: ['w'],
        additionalProperties: false,
      },
    },
  },
  required: ['id', 'words'],
  additionalProperties: false,
}

const PICKS = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    picks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          w: { type: 'string' },
          pos: { type: 'string' },
          pick: { type: 'integer' },
        },
        required: ['w', 'pick'],
        additionalProperties: false,
      },
    },
  },
  required: ['id', 'picks'],
  additionalProperties: false,
}

const AUDIT = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    problems: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          w: { type: 'string' },
          action: { type: 'string', enum: ['drop', 'pick'] },
          pick: { type: 'integer' },
          why: { type: 'string' },
        },
        required: ['w', 'action', 'why'],
        additionalProperties: false,
      },
    },
  },
  required: ['id', 'problems'],
  additionalProperties: false,
}

function candidatesPrompt(id) {
  return `You are curating a THEME word list for an English learner's app — it must feel hand-made by a great teacher. Read /tmp/ready_new/brief_${id}.json: {id, name, description, guidance, target_new}.

Propose ${'~'}75 candidate words for this exact list (over-supply: some will not survive dictionary checks). Rules:
- Follow the guidance strictly: topic scope, the CEFR level, and the AVOID list.
- Real English lemmas in lowercase ("beak", "runway", "stand-up"); multiword items only when they are true dictionary headwords.
- Each item: {"w": "<lemma>", "pos": "<noun|verb|adj|adv>"} — set pos to the part of speech that carries the topical meaning (e.g. "toast" pos noun for the bar list). Omit pos only if any part of speech works.
- Mix parts of speech naturally; no proper nouns; no words whose ONLY meaning belongs to another theme from the AVOID note.
- Order from most essential to nice-to-have.

Return ONLY via StructuredOutput as {id: "${id}", words: [...]}. The Read of the brief is your single allowed tool call.`
}

function picksPrompt(id) {
  return `You are binding each candidate word of a themed learner list to ONE dictionary sense. Read /tmp/ready_v2/work/${id}/probe.json — an array of {w, pos, found, defs: [{i, pos, d}]} (defs are ordered by importance). The theme brief is /tmp/ready_new/brief_${id}.json (read both files; two Read calls allowed).

For every candidate with found=true, decide:
- pick = the index i of the definition that matches the THEME's meaning of the word (usually 0; choose a later one when the topical meaning is not first — e.g. for a bar list "shot" must bind to the drink sense, not the gunshot).
- Copy the word's pos from probe.json VERBATIM — never add, drop, or change it: pick indices are only valid for the exact def list probe.json shows, and that list depends on pos.
- OMIT words entirely (do not include them in picks) when: found=false, none of the defs carries the topical meaning, the word is off-level, off-topic, or belongs to an AVOID theme.

Quality bar: the picked definition will be printed on the word's card — it must read as obviously belonging to this theme.

Return ONLY via StructuredOutput as {id: "${id}", picks: [{w, pos?, pick}...]}.`
}

function auditPrompt(id) {
  return `You are the final auditor of a themed learner word list. Read /tmp/ready_new/render_${id}.txt — every word with its BOUND definition (the one shown on its card) plus numbered alternatives, and /tmp/ready_new/brief_${id}.json for the theme/level contract (two Read calls allowed).

Flag ONLY real problems:
- {"w", "action": "drop", "why"} — off-topic for the theme, badly off-level, a duplicate concept already covered by a better word in this list, or no listed definition fits the theme.
- {"w", "action": "pick", "pick": N, "why"} — the bound definition is the WRONG sense for this theme and alternative N is right. "pick" is REQUIRED for this action; a pick problem without it is discarded.

Do not flag taste-level quibbles and do NOT trim for size — a big list of good words is welcome; a good list survives with zero or few problems. Return ONLY via StructuredOutput as {id: "${id}", problems: [...]}.`
}

const prompts = { candidates: candidatesPrompt, picks: picksPrompt, audit: auditPrompt }
const schemas = { candidates: CANDIDATES, picks: PICKS, audit: AUDIT }

const stage = args.stage
const build = prompts[stage]
const schema = schemas[stage]

phase('Lists')
const results = await parallel(args.ids.map(id => () => agent(
  build(id),
  { label: `${stage}:${id}`, phase: 'Lists', schema }
)))

const ok = results.filter(Boolean)
log(`${ok.length}/${args.ids.length} lists done`)
return { stage, requested: args.ids.length, completed: ok.length, results: ok.map(r => r.id) }
