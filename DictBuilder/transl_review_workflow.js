export const meta = {
  name: 'dict-translation-review',
  description: 'Validate per-sense Russian translations: sense mismatch and unnatural Russian get rewritten',
  phases: [{ title: 'Review', detail: 'haiku, single-call agents, verdicts via StructuredOutput' }],
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
                t: { type: 'string' },
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

const RULES = `Ты проверяешь русские переводы в англо-русском учебном словаре. Перевод привязан к КОНКРЕТНОМУ значению (sense) английского слова. Каждая группа — одно английское слово со ВСЕМИ его значениями: {id: "<слово>", s: [{i, p (часть речи), d (определение значения), t? (текущий русский перевод)}]}. Судить нужно ТОЛЬКО значения, у которых есть "t"; остальные даны как контекст, чтобы различать соседние смыслы.

Два вида ошибок, которые ты ищешь:
1. Перевод не того смысла. У raspberry значение "куст с шипами" должно быть «малиновый куст», а не «малина» — «малина» это ягода, соседний смысл. Перевод обязан соответствовать именно СВОЕМУ определению d, а не самому частому смыслу слова.
2. Неестественный русский. wetland -> «водно-болотные угодья» — канцелярит, живой человек скажет «болотистая местность». Перевод должен быть словом или коротким словосочетанием, которое реально говорят по-русски.

Вердикты, ровно по одному на каждое значение с "t", в том же порядке:
- {"i": N, "a": "keep"} — перевод точен для этого смысла и звучит естественно.
- {"i": N, "a": "rw", "t": "<новый перевод>"} — когда перевод не о том смысле или корявый. Новый перевод: ОДНО слово или короткое словосочетание (без запятых, слэшей и скобок — никаких перечислений), кириллицей, максимум 40 символов, та же часть речи, что у английского значения (глагол — инфинитивом).
- {"i": N, "a": "del"} — только если разумного русского перевода для этого смысла не существует и текущий вводит в заблуждение.

Не трогай хорошие переводы ради вкусовщины — «keep» это нормальный исход для большинства. Верни результат ТОЛЬКО через StructuredOutput как {verdicts:[{id, v:[...]}]} — не пиши файлов и не выполняй других команд.`

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

phase('Review')
const results = await parallel(nums.map(n => () => agent(
  `${RULES}\n\nПрочитай файл ${args.workdir}/batch_${n}.json (это твой единственный разрешённый вызов инструмента) и вынеси вердикты.`,
  { label: `tr:${n}`, phase: 'Review', schema: VERDICTS, model: args.model || 'haiku', effort: args.effort || 'low' }
)))

const ok = results.filter(Boolean)
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
log(`${ok.length}/${nums.length} batches, ${groups} groups`)
return { batches: nums.length, completed: ok.length, groups, kept, rewritten, deleted }
