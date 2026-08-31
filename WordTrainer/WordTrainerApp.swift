import SwiftUI
import SwiftData

@main
struct WordTrainerApp: App {
    @State private var dictionaryReady: Bool = !DictionaryDownloader.isConfigured
        || DictionaryDownloader.isInstalled

    let container: ModelContainer = {
        let schema = Schema([
            WordGroup.self, Word.self, WordSense.self, CustomSense.self,
            QuizSession.self, QuizResult.self, SenseStats.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            #if DEBUG
            fatalError("SwiftData ModelContainer init failed. Wipe the app and retry. \(error)")
            #else
            NSLog("[WordTrainer] ModelContainer init failed, using in-memory fallback: %@", String(describing: error))
            do {
                let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                fatalError("ModelContainer in-memory fallback also failed: \(error)")
            }
            #endif
        }
    }()

    init() {
        Self.repairDuplicateCustomSenseIDs(container)
        Self.backfillSenseStats(container)
    }

    // The move from per-WordSense counters to global SenseStats dropped the old
    // columns in migration; saved QuizResult rows record the same events, so
    // rebuild the counters from them once, while the SenseStats table is empty.
    private static func backfillSenseStats(_ container: ModelContainer) {
        let context = ModelContext(container)
        guard ((try? context.fetchCount(FetchDescriptor<SenseStats>())) ?? 0) == 0,
              let results = try? context.fetch(FetchDescriptor<QuizResult>()),
              !results.isEmpty
        else { return }
        for result in results {
            let stats = SenseStats.findOrInsert(lemma: result.lemma,
                                                definition: result.senseDefinition,
                                                in: context)
            stats.timesSeen += 1
            if result.isCorrect { stats.timesCorrect += 1 }
        }
        try? context.save()
    }

    // Pre-existing rows get one shared UUID backfilled by the migration.
    private static func repairDuplicateCustomSenseIDs(_ container: ModelContainer) {
        let context = ModelContext(container)
        var changed = false

        func repair<T: PersistentModel>(_ type: T.Type, id: ReferenceWritableKeyPath<T, UUID>) {
            guard let all = try? context.fetch(FetchDescriptor<T>()) else { return }
            var seen = Set<UUID>()
            for row in all {
                if seen.contains(row[keyPath: id]) {
                    row[keyPath: id] = UUID()
                    changed = true
                }
                seen.insert(row[keyPath: id])
            }
        }

        repair(CustomSense.self, id: \CustomSense.id)
        repair(WordGroup.self, id: \WordGroup.id)
        if changed { try? context.save() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if dictionaryReady {
                    GroupsListView()
                } else {
                    DictionaryLoaderView { dictionaryReady = true }
                }
            }
        }
        .modelContainer(container)
    }
}
