export const meta = {
  name: 'total-code-review',
  description: 'Full review of the WordAce app codebase: finders per dimension, adversarial verification of every finding',
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
const COMMON = `You are reviewing the WordAce iOS app (SwiftUI + SwiftData, iOS 17+) at ${ROOT}/WordAce (tests in ${ROOT}/WordAceTests). Read the actual code — every finding must cite real file:line and describe a concrete failure scenario reachable by a user. Do NOT report style nits, hypotheticals you did not trace, or intended behavior. Key invariants: learn status/points identity is global per (lemma, definition) via SenseStats; learned exists only via points >= threshold; quiz asks one question per word; medals grade against quizzable words; the app pins dark appearance with Color.appBackground canvas and Color.cardSurface surfaces. Report via StructuredOutput {findings:[...]}.`

const DIMENSIONS = [
  { key: 'model', prompt: `${COMMON}\nDimension: DATA MODEL & LOGIC. Files: Models/Models.swift, Quiz/QuizEngine.swift. Hunt: invariant violations in SenseStats/auto-learn/reset, merge/absorb/cloneSenses edge cases (order collisions, dedup misses, cascade deletes), Medal/percent math, QuizBuilder candidate selection, scoring edge cases, normalization gaps (lemma casing/trim mismatches between paths).` },
  { key: 'flows', prompt: `${COMMON}\nDimension: UI FLOWS & STATE. Files: Views/GroupsListView.swift, Views/GroupDetailView.swift, Views/WordDetailView.swift, Views/GroupStatsView.swift. Hunt: stale state after navigation/sheet dismissal, selection-mode leaks, swipe actions with wrong guards, alerts losing their subject, cross-tab jump bugs, delete flows leaving dangling references, @Query misuse.` },
  { key: 'quiz', prompt: `${COMMON}\nDimension: QUIZ FUNNEL. Files: Views/QuizRunnerView.swift, Views/QuizConfigSheet.swift, Quiz/QuizEngine.swift. Hunt: downgrade funnel state bugs (boxes/hints/typed letters across question advance), focus/keyboard traps, points accounting mismatches between UI and saveStats, summary double-save, include-learned interactions, AnswerSlots edge cases (separators, apostrophes, hints on short words).` },
  { key: 'lookup', prompt: `${COMMON}\nDimension: DICTIONARY & LOOKUP. Files: Views/WordLookupView.swift, Dictionary/*.swift, Views/SharedViews.swift (WordLink/LinkedText). Hunt: search debounce/cancellation races, loadedLemma guard correctness (in-flight replacement, pop-back), quick-add menu correctness, custom sense dedup, downloader state machine (retry, checksum failure, partial file), deep-link parsing.` },
  { key: 'theme', prompt: `${COMMON}\nDimension: FRESH DARK THEME. All Views/*.swift. The theme wave just replaced system backgrounds with Color.appBackground/.cardSurface via appScreen()/cardSurfaceRow(), pinned .preferredColorScheme(.dark), made the tab bar opaque, and replaced button press-fade with SolidPressStyle. Hunt: screens or sheets MISSED by appScreen (still black/system bg), rows still on default #1C1C1E wells, text/icons with poor contrast on the new surfaces (secondary on cardSurface, systemGray on dark), leftover Color(.system*) usages, glows/washes that became invisible, toolbarBackground(.visible, for: .navigationBar) regressions (it kills large titles on this SDK - must not be present).` },
  { key: 'perf', prompt: `${COMMON}\nDimension: PERFORMANCE & CONCURRENCY. All app files. Hunt: per-row O(n) scans over @Query arrays inside ForEach (quadratic lists), fetches inside loops, main-thread SQLite I/O, tasks not cancelled, Observation invalidation gaps (background views not repainting), retain cycles via closures in long-lived objects, work re-done every body evaluation.` },
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
        `Adversarially verify this finding about the WordAce app at ${ROOT}. Try hard to REFUTE it by reading the actual code and tracing the exact scenario end to end; only confirm if the failure is real and reachable. Finding: [${f.severity}] ${f.file}:${f.line} — ${f.title}\n${f.detail}\nReturn StructuredOutput {real, confidence: CONFIRMED only if you traced it fully, note}.`,
        { label: `verify:${d.key}:${f.line}`, phase: 'Verify', schema: VERDICT }
      ).then(v => ({ ...f, dimension: d.key, verdict: v }))
    ))
  }
)

const all = results.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter(f => f.verdict && f.verdict.real)
log(`${all.length} findings, ${confirmed.length} survived`)
return { total: all.length, confirmed }
