export const meta = {
  name: 'dict-translation-gen',
  description: 'Give every dictionary sense a precise 1-2 word Russian translation, or skip when none exists',
  phases: [{ title: 'Translate', detail: 'haiku, single-call agents, verdicts via StructuredOutput' }],
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
                a: { type: 'string', enum: ['add', 'skip'] },
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

const RULES = `Ты добавляешь русские переводы в англо-русский учебный словарь. Перевод привязан к КОНКРЕТНОМУ значению (sense). Каждая группа — одно английское слово со ВСЕМИ его значениями: {id: "<слово>", s: [{i, p (часть речи), d (определение значения), t? (существующий перевод), x? (1 = это значение нужно перевести)}]}. Работай ТОЛЬКО со значениями, помеченными "x"; остальные и их переводы "t" — контекст, чтобы различать соседние смыслы и не дублировать их переводы.

Правила перевода:
- ОДНО слово или словосочетание из ДВУХ слов. Два слова — это нормально и часто точнее: у raspberry смысл «куст» — «малиновый куст», а не «малина» (это соседний смысл-ягода). Три и больше слов — почти всегда признак, что точного перевода нет: тогда skip. (Исключение: если сам английский заголовок — фраза из 3+ слов, перевод может быть такой же длины.)
- Перевод должен соответствовать именно СВОЕМУ определению d, а не самому частому смыслу слова.
- Живой, естественный русский — то, что реально говорят; никакого канцелярита («водно-болотные угодья» — плохо, «болотистая местность» — хорошо).
- Та же часть речи: глагол — инфинитивом, существительное — существительным.
- Без запятых, слэшей, скобок и перечислений — ровно один вариант, кириллицей, до 40 символов.
- Если значение помечено "x" и у него УЖЕ есть "t" — текущий перевод слишком многословный: дай сжатый в 1-2 слова, либо skip, если сжать честно нельзя.
- skip — правильный выбор для служебных смыслов, узкой грамматики и всего, где один точный русский эквивалент не существует. Натянутый перевод хуже пустого.

Вердикты, ровно по одному на каждое значение с "x", в том же порядке:
- {"i": N, "a": "add", "t": "<перевод>"}
- {"i": N, "a": "skip"}

Верни результат ТОЛЬКО через StructuredOutput как {verdicts:[{id, v:[...]}]} — не пиши файлов и не выполняй других команд.`

const nums = Array.from({ length: args.count }, (_, i) => String(args.start + i).padStart(4, '0'))

phase('Translate')
const results = await parallel(nums.map(n => () => agent(
  `${RULES}\n\nПрочитай файл ${args.workdir}/batch_${n}.json (это твой единственный разрешённый вызов инструмента) и вынеси вердикты.`,
  { label: `tg:${n}`, phase: 'Translate', schema: VERDICTS, model: args.model || 'haiku', effort: args.effort || 'low' }
)))

const ok = results.filter(Boolean)
let groups = 0, added = 0, skipped = 0
for (const r of ok) {
  for (const g of r.verdicts) {
    groups += 1
    for (const v of g.v) {
      if (v.a === 'add') added += 1
      else skipped += 1
    }
  }
}
log(`${ok.length}/${nums.length} batches, ${groups} groups`)
return { batches: nums.length, completed: ok.length, groups, added, skipped }
