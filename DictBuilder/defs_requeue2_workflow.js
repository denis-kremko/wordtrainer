export const meta = {
  name: 'dict-defs-requeue-2',
  description: 'Second pass on groups that failed validation: rewrite definitions without echoing the headword root',
  phases: [{ title: 'Definitions', detail: 'haiku agents, ~160 senses per batch' }],
}

const SUMMARY = {
  type: 'object',
  properties: {
    groups: { type: 'integer' },
    kept: { type: 'integer' },
    rewritten: { type: 'integer' },
    deleted: { type: 'integer' },
  },
  required: ['groups', 'kept', 'rewritten', 'deleted'],
  additionalProperties: false,
}

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

phase('Definitions')
const results = await parallel(nums.map(n => () => agent(
`You are raising the quality of an English learner's dictionary. The rule: a definition must EXPLAIN the meaning in simple words, not list synonyms. A learner who reads it should understand what the word means and what is specific about it (typical manner, object, tone, context) — without knowing any of its synonyms.

Read the file ${args.workdir}/batch_${n}.json — a JSON array of groups. Each group is {id: "headword|pos", s: [{i, d (definition), e (usage example), p?}]} — all senses of one headword for one part of speech, most common first.

For EACH group output exactly one JSON line in ${args.workdir}/verdict_${n}.jsonl. Build the file INCREMENTALLY: append after every ~10 groups via Bash (cat >> heredoc), never one huge final write — a single giant response gets truncated and loses everything. Line format:
{"id": "<same id>", "v": [<one verdict per sense, same order>]}

Verdict actions:
- {"i": N, "a": "keep"} — the definition already explains the meaning plainly.
- {"i": N, "a": "rw", "d": "<rewrite>"} — REQUIRED when the definition is mostly a synonym chain, uses vocabulary harder than ~B1, or hides what makes the word specific. The rewrite: plain A1-B1 words; one clear explanation including the word's own specifics (no comparisons with synonyms needed); 20-220 characters — longer but simpler beats short and vague; at most one clarifying synonym, only in parentheses at the end; MUST NOT contain any word sharing a root with the headword — this was the #1 failure of the previous pass: before answering, check EVERY word of your rewrite against the headword and its stems (for "preside" reject "president", "presiding"; for "runner" reject "run", "running") and reformulate until none remain, falling back to {"a": "keep"} if the meaning is inexpressible without the root; must stay compatible with the example e; never a cross-reference ("Alternative form of...") and never starts with a parenthesis.
- {"i": N, "a": "del"} — delete a sense whose meaning a learner already gets from another kept/rewritten sense of this group: if you know that one, you know this one. Be aggressive about these; genuinely distinct meanings always stay. Never delete a sense with "p" set; every group must keep at least one non-deleted sense.
- Senses with "p": 2 are locked — always {"a": "keep"} (use them as context for dedup decisions).
- Senses with "p": 1 may be rewritten but never deleted.

The standard you are writing to:
BAD (synonym chain): "To delay or impede; to keep back, to prevent."
GOOD: "To make something happen more slowly or with more difficulty; to get in the way of progress."
Dedup example — crew: keep "A group of people working together on a task." and delete "The group of workers on a dramatic production who are not part of the cast." (a narrow sub-case a learner gets for free).

Every sense id of every group must appear exactly once. Then call StructuredOutput with the summary counts {groups, kept, rewritten, deleted}.`,
  { label: `defsR:${n}`, phase: 'Definitions', schema: SUMMARY, model: 'sonnet' }
)))

const ok = results.filter(Boolean)
log(`${ok.length}/${nums.length} batches completed`)
return {
  batches: nums.length,
  completed: ok.length,
  groups: ok.reduce((s, r) => s + r.groups, 0),
  kept: ok.reduce((s, r) => s + r.kept, 0),
  rewritten: ok.reduce((s, r) => s + r.rewritten, 0),
  deleted: ok.reduce((s, r) => s + r.deleted, 0),
}
