export const meta = {
  name: 'dict-crosspos-rank',
  description: 'Delete parasitic cross-POS senses and set one global importance order per lemma',
  phases: [{ title: 'Rank', detail: 'haiku agents, 40 lemmas per batch' }],
}

const SUMMARY = {
  type: 'object',
  properties: {
    lemmas: { type: 'integer' },
    deleted: { type: 'integer' },
  },
  required: ['lemmas', 'deleted'],
  additionalProperties: false,
}

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

phase('Rank')
const results = await parallel(nums.map(n => () => agent(
`You are cleaning an English learner's dictionary. Read ${args.workdir}/batch_${n}.json — a JSON array of lemmas. Each element is {id: lemma, s: [{i, p (part of speech), d (definition), e (example), prot?}]} — ALL senses of that lemma across every part of speech.

Two jobs per lemma:
1. DELETE parasitic senses. A sense is parasitic when its whole meaning is a mechanical restatement of the same lemma in another part of speech and learners rarely meet it in real usage. Example — crew: the verb sense "to be a member of a crew" is parasitic on the noun and must go. Typical parasites: "to act as / be / work as a X", "the act or result of Xing" when it adds nothing over the verb, "of or relating to X". BUT if the conversion is genuinely common in real English (a run, a walk, to email, a find), KEEP it. Never delete a sense with "prot": 1 (you may still rank it anywhere). Every lemma keeps at least one sense. Genuinely distinct meanings always stay.
2. RANK all kept senses in ONE order across parts of speech: the meaning a learner most needs first, by real-life frequency of that meaning. The first id decides which part-of-speech block the app shows on top (run → a verb sense first; crew → a noun sense first).

For each lemma output exactly one JSON line, same order as the batch, into ${args.workdir}/verdict_${n}.jsonl:
{"id": "<lemma>", "o": [kept ids, most important first], "x": [deleted ids]}
Every sense id of the lemma must appear exactly once across o and x. Write incrementally: append every ~10 lemmas with a shell >> redirect instead of one giant write.

Then call StructuredOutput with {lemmas, deleted} counts.`,
  { label: `xpos:${n}`, phase: 'Rank', schema: SUMMARY, model: 'haiku' }
)))

const ok = results.filter(Boolean)
log(`${ok.length}/${nums.length} batches completed`)
return {
  batches: nums.length,
  completed: ok.length,
  lemmas: ok.reduce((s, r) => s + r.lemmas, 0),
  deleted: ok.reduce((s, r) => s + r.deleted, 0),
}
