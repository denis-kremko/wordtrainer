export const meta = {
  name: 'dict-defs-simplicity',
  description: 'Rewrite synonym-chain and hard-vocabulary definitions into plain A1-B1 explanations',
  phases: [{ title: 'Rewrite', detail: 'haiku, single-call agents, verdicts via StructuredOutput' }],
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
          v: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                i: { type: 'integer' },
                a: { type: 'string', enum: ['keep', 'rw', 'del'] },
                d: { type: 'string' },
              },
              required: ['i', 'a'],
              additionalProperties: false,
            },
          },
        },
        required: ['id', 'v'],
        additionalProperties: false,
      },
    },
  },
  required: ['verdicts'],
  additionalProperties: false,
}

const RULES = `You are raising the quality of an English learner's dictionary. THE RULE OF THIS PASS: a definition must EXPLAIN the meaning using words MORE COMMON than the headword itself. Target A1-B1 vocabulary (roughly the 3,000 most common English words). It is always wrong to describe an easy word with a harder one.

BANNED:
- Synonym chains: "Clever; amusingly ingenious." or "Nimble with hands or body; dexterous; skillful; adept." teach nothing.
- Content words rarer than the headword: defining "clever" (common) via "dexterous" or "adept" (rare) is the worst kind of mistake.
- Circular definitions: never define "witty" via "ingenious" when "ingenious" is itself defined via "witty".

GOOD rewrites:
- witty -> "Funny in a clever way: quick to say smart things that make people laugh."
- clever (hands sense) -> "Good at doing things with your hands; quick and exact in small movements."

Verdict actions, one per sense, same order as the input:
- {"i": N, "a": "keep"} - already a plain explanation in common words.
- {"i": N, "a": "rw", "d": "<rewrite>"} - REQUIRED when the definition is a synonym chain, uses words rarer than the headword, or hides the meaning. The rewrite: 20-220 characters; one clear explanation carrying the word's own specifics (typical manner, object, tone, context); every content word an A1-B1 learner knows; MUST NOT contain any word sharing a root with the headword; must stay compatible with the example "e" when present; at most one clarifying synonym, only in parentheses at the end, and only if that synonym is itself a very common word; never a cross-reference and never starts with a parenthesis.
- {"i": N, "a": "del"} - only when the meaning is already fully covered by another kept/rewritten sense of the SAME group. Never delete a sense with "p" set; a "p":2 sense must be exactly {"a":"keep"}; every group keeps at least one non-deleted sense.

FINAL SELF-CHECK on every rewrite before you submit: (1) it contains NO form of the headword and no word sharing its root or first 4+ letters; (2) no semicolon-separated bare synonyms and no trailing "; word." tail; (3) every content word is an everyday word a beginner knows.

Groups are {id: "headword|pos", s: [{i, d (definition), e (usage example), p?}]}. A group may carry "note" - feedback on why its previous rewrite attempt was rejected; treat the note as a hard requirement and fix exactly that problem. Every sense id of every group must appear exactly once. Submit the result ONLY via StructuredOutput as {verdicts:[{id, v:[...]}]} - do not write any files, do not run any other commands.`

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

// sonnet hangs forever emitting LONG StructuredOutput arguments (probed 2026-09-01);
// noschema mode returns the same JSON as plain text instead.
const useSchema = !args.noschema
const TEXT_TAIL = ' Instead of StructuredOutput, return ONLY the raw JSON object as your final message text - no markdown fences, no commentary - with EXACTLY this nesting: {"verdicts":[{"id":"<group id>","v":[{"i":<sense id>,"a":"keep|rw|del","d":"<rewrite, only when a=rw>"}]}]} - one verdicts entry per group, one v entry per sense.'

phase('Rewrite')
const results = await parallel(nums.map(n => () => agent(
  `${RULES}\n\nNow Read the file ${args.workdir}/batch_${n}.json (your one allowed tool call) and produce the verdicts.${useSchema ? '' : TEXT_TAIL}`,
  { label: `simp:${n}`, phase: 'Rewrite', ...(useSchema ? { schema: VERDICTS } : {}), model: args.model === 'inherit' ? undefined : (args.model || 'haiku'), effort: args.effort || undefined }
)))

let unparsed = 0
const ok = results.filter(Boolean).map(r => {
  if (typeof r !== 'string') return r
  try {
    return JSON.parse(r.slice(r.indexOf('{'), r.lastIndexOf('}') + 1))
  } catch (e) {
    unparsed += 1
    return null
  }
}).filter(Boolean)
let groups = 0, kept = 0, rewritten = 0, deleted = 0
for (const r of ok) {
  for (const g of r.verdicts) {
    groups += 1
    for (const v of g.v) {
      if (v.a === 'keep') kept += 1
      else if (v.a === 'rw') rewritten += 1
      else deleted += 1
    }
  }
}
log(`${ok.length}/${nums.length} batches, ${groups} groups${unparsed ? `, ${unparsed} unparsed` : ''}`)
return { batches: nums.length, completed: ok.length, unparsed, groups, kept, rewritten, deleted }
