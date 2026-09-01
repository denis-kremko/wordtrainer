import SwiftUI

struct DictionaryLoaderView: View {
    @State private var downloader = DictionaryDownloader()
    let onReady: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Preparing your dictionary")
                .font(.title2).bold()

            content

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .onAppear { downloader.start() }
        .onChange(of: downloader.state) { _, new in
            if case .done = new { onReady() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloader.state {
        case .idle:
            ProgressView().controlSize(.large)

        case .downloading(let received, let total):
            VStack(spacing: 12) {
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                    Text("\(bytes(received)) of \(bytes(total)) downloaded")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("\(bytes(received)) downloaded")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("First launch only. About 60 MB. You can use the app after this finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) { downloader.cancel() }
                    .padding(.top, 4)
            }

        case .verifying:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("Verifying…").foregroundStyle(.secondary)
            }

        case .installing:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("Installing…").foregroundStyle(.secondary)
            }

        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Ready").foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Download failed").font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    downloader = DictionaryDownloader()
                    downloader.start()
                }
                .buttonStyle(.borderedProminent)
                if DictionaryService.shared.isAvailable {
                    // What opens is whatever openBest found: the previous full
                    // dictionary when one is installed, the demo otherwise.
                    Button("Continue offline") { onReady() }
                }
            }
        }
    }


    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(n, 0), countStyle: .file)
    }
}
