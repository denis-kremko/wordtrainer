export const meta = {
  name: 'dict-restore-primary-senses',
  description: 'Restore important senses the original build filtered out (taxonomy/anaphora glosses), written as plain explanations',
  phases: [{ title: 'Restore', detail: 'session model, single-call agents' }],
}

const VERDICTS = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          add: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                pos: { type: 'string' },
                d: { type: 'string' },
                first: { type: 'boolean' },
                t: { type: 'string' },
              },
              required: ['pos', 'd', 'first'],
              additionalProperties: false,
            },
          },
        },
        required: ['id', 'add'],
        additionalProperties: false,
      },
    },
  },
  required: ['verdicts'],
  additionalProperties: false,
}

const RULES = `You are repairing an English learner's dictionary. The original build accidentally dropped some words' MOST IMPORTANT senses, because Wiktionary wrote them as taxonomy ("A tree of the genus Castanea") or anaphora ("The nut of this tree"). Example of the damage: "chestnut" ended up with only the color/horse/wood senses — the NUT itself was missing.

Each group: {id: "<lemma>", current: [существующие senses {pos, d}], candidates: [{pos, idx, gloss}] — glosses from Wiktionary that look absent from current}. For each lemma decide which candidate meanings are GENUINELY important for a learner and truly absent, and write them anew:

- {"pos": "<noun|verb|adj|adv|...>", "d": "<новое определение>", "first": true/false, "t": "<русский перевод>"}
- The definition: a self-contained plain-English explanation (A1-B1 vocabulary), 20-220 characters, NO taxonomy latin, NO references to other senses ("this tree" is banned — say "the chestnut tree" ... no wait, NO word sharing a root with the lemma either; describe it: "A large sweet nut with a shiny brown shell that you can roast and eat."), compatible with everyday usage.
- first=true when this is the word's PRIMARY everyday meaning and must be shown before all current senses (chestnut nut -> first). Otherwise false.
- "t": ONE Russian word (or two-word phrase) for this sense, Cyrillic; omit "t" if no precise translation exists.
- Skip candidates that are: niche/dated/technical meanings, already covered by a current sense (reworded), or not worth a learner's attention. Empty "add" is a normal outcome.
- Add at most 2 senses per lemma.

Return ONLY via StructuredOutput as {verdicts: [{id, add: [...]}]} — one verdict per group, no files, no other commands.`

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

phase('Restore')
const results = await parallel(nums.map(n => () => agent(
  `${RULES}\n\nRead the file ${args.workdir}/batch_${n}.json (your one allowed tool call) and produce the verdicts.`,
  { label: `rs:${n}`, phase: 'Restore', schema: VERDICTS, effort: 'low' }
)))

const ok = results.filter(Boolean)
let groups = 0, added = 0, firsts = 0
for (const r of ok) {
  for (const g of r.verdicts) {
    groups += 1
    added += g.add.length
    firsts += g.add.filter(a => a.first).length
  }
}
log(`${ok.length}/${nums.length} batches, ${groups} lemmas, ${added} restored`)
return { batches: nums.length, completed: ok.length, groups, added, firsts }
