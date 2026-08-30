import SwiftUI
import SwiftData

@main
struct WordTrainerApp: App {
    @State private var dictionaryReady: Bool = !DictionaryDownloader.isConfigured
        || DictionaryDownloader.isInstalled

    // Built by hand so a broken schema fails loudly instead of silently
    // falling back to an empty in-memory store (as `.modelContainer(for:)` does).
    let container: ModelContainer = {
        let schema = Schema([WordGroup.self, Word.self, WordSense.self])
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
