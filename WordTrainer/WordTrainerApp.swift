import SwiftUI
import SwiftData

@main
struct WordTrainerApp: App {
    @State private var dictionaryReady: Bool = !DictionaryDownloader.isConfigured
        || DictionaryDownloader.isInstalled

    let container: ModelContainer = {
        let schema = Schema([
            WordGroup.self, Word.self, WordSense.self, CustomSense.self,
            QuizSession.self, QuizResult.self,
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
    }

    // Pre-existing rows get one shared UUID backfilled by the migration.
    private static func repairDuplicateCustomSenseIDs(_ container: ModelContainer) {
        let context = ModelContext(container)
        guard let all = try? context.fetch(FetchDescriptor<CustomSense>()) else { return }
        var seen = Set<UUID>()
        var changed = false
        for sense in all {
            if seen.contains(sense.id) {
                sense.id = UUID()
                changed = true
            }
            seen.insert(sense.id)
        }
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
