export const meta = {
  name: 'recent-features-review',
  description: 'Review the post-d63dfe1 feature wave (translations, spoiler, quiz modes, card lists) for bugs and corner cases',
  phases: [{ title: 'Find' }, { title: 'Verify' }],
}

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          detail: { type: 'string' },
          severity: { type: 'string', enum: ['bug', 'polish'] },
        },
        required: ['file', 'line', 'title', 'detail', 'severity'],
        additionalProperties: false,
      },
    },
  },
  required: ['findings'],
  additionalProperties: false,
}

const VERDICT = {
  type: 'object',
  properties: {
    real: { type: 'boolean' },
    confidence: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE'] },
    note: { type: 'string' },
  },
  required: ['real', 'confidence', 'note'],
  additionalProperties: false,
}

const ROOT = '/Users/deniskremko/wordtrainer'
const COMMON = `You are reviewing the WordAce iOS app (SwiftUI + SwiftData, iOS 17+) at ${ROOT}. The review scope is the recent feature wave: run \`git -C ${ROOT} diff d63dfe1..HEAD --stat\` and read the diff plus surrounding code. Recent features: flat rank-ordered dictionary senses with POS tags; one-card-per-item lists everywhere; per-sense Russian translations (translations table joined in DictionaryService, WordSense.translation/CustomSense.translation, custom-sense and Modify-sense forms); Telegram-style dust spoiler (SpoilerText/SpoilerDust in SharedViews); quiz Definitions/Translations mode toggle; checksum-gated dictionary auto-update. HARD RULES: read code only — do NOT build, run, install, or launch anything, no xcodebuild/simctl/osascript, no repro apps. Every finding must cite real file:line with a concrete user-reachable failure. No style nits. Report via StructuredOutput {findings:[...]}.`

const DIMENSIONS = [
  { key: 'translations-data', prompt: `${COMMON}\nDimension: TRANSLATION DATA FLOW. Files: Models/Models.swift, Dictionary/DictionaryService.swift, Dictionary/DictionaryDownloader.swift. Hunt: translation propagation gaps (appendSenses/cloneSenses/absorb, custom vs dictionary senses), nilIfEmpty/empty-string semantics mismatches, findOrInsert translation update rules, LEFT JOIN correctness, the installedSHA UserDefaults gate (app reinstall, download cancel mid-way, checksum change while running).` },
  { key: 'spoiler', prompt: `${COMMON}\nDimension: SPOILER UI. Files: Views/SharedViews.swift (SpoilerText/SpoilerDust/SplitMix), its call sites in WordLookupView/WordDetailView. Hunt: state lifecycle bugs (revealed/settled/revealedAt across row reuse, navigation pop, sense edits), TimelineView pause correctness, tap conflicts inside selection Buttons and swipe rows, layout when the translation is long (wrapping vs minWidth), dissolve mid-flight re-tap.` },
  { key: 'quiz-modes', prompt: `${COMMON}\nDimension: QUIZ MODES. Files: Quiz/QuizEngine.swift, Views/QuizConfigSheet.swift, Views/QuizRunnerView.swift, Views/GroupStatsView.swift, Models (Medal/scorePercent). Hunt: translation-mode corner cases (word whose only translated sense is disabled/learned, include-learned interplay, empty prompt questions, eligible vs builder drift), mode persistence across groups, stats/medals semantics with mixed-mode sessions, boxes/hints on Russian prompts (expected answer is still English — verify nothing assumes prompt language).` },
  { key: 'lists-and-forms', prompt: `${COMMON}\nDimension: CARD LISTS AND FORMS. Files: Views/WordLookupView.swift, Views/GroupDetailView.swift, Views/GroupStatsView.swift, Views/ReadyGroupsView.swift. Hunt: header-on-first-index breakage when lists filter/reorder/empty, custom-sense add/modify flows (draft translation state reset between lemmas, findOrInsert dedup with changed translation), swipe-delete on per-card custom senses, Contains/Results card conversions, stale selection after deletes.` },
]

phase('Find')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `find:${d.key}`, phase: 'Find', schema: FINDINGS }),
  (found, d) => {
    if (!found || !found.findings.length) return []
    log(`${d.key}: ${found.findings.length} findings`)
    return parallel(found.findings.map(f => () =>
      agent(
        `Adversarially verify this finding about the WordAce app at ${ROOT}. Try hard to REFUTE it by reading the actual code and tracing the exact scenario end to end; only confirm if the failure is real and reachable. READ CODE ONLY: no builds, no simulators, no repro apps, no xcodebuild/simctl/osascript. Finding: [${f.severity}] ${f.file}:${f.line} — ${f.title}\n${f.detail}\nReturn StructuredOutput {real, confidence: CONFIRMED only if you traced it fully, note}.`,
        { label: `verify:${d.key}:${f.line}`, phase: 'Verify', schema: VERDICT }
      ).then(v => ({ ...f, dimension: d.key, verdict: v }))
    ))
  }
)

const all = results.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter(f => f.verdict && f.verdict.real)
log(`${all.length} findings, ${confirmed.length} survived`)
return { total: all.length, confirmed }
