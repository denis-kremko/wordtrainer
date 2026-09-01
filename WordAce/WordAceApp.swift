import SwiftUI
import SwiftData

@main
struct WordAceApp: App {
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
            NSLog("[WordAce] ModelContainer init failed, using in-memory fallback: %@", String(describing: error))
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
            .onAppear { Keyboard.installTapToDismiss() }
            .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}
