import SwiftUI
import SwiftData
import Charts

struct GroupStatsView: View {
    private let groupName: String
    @Query private var sessions: [QuizSession]

    init(groupName: String) {
        self.groupName = groupName
        _sessions = Query(
            filter: #Predicate<QuizSession> { $0.groupName == groupName },
            sort: \QuizSession.date
        )
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No saved quizzes",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Finish a quiz and tap “Save to statistics” to start tracking progress.")
                )
            } else {
                List {
                    Section {
                        summaryTiles
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section("Progress") {
                        progressChart
                            .frame(height: 220)
                            .padding(.vertical, 8)
                    }
                    Section("History") {
                        ForEach(Array(sessions.enumerated().reversed()), id: \.element.persistentModelID) { index, session in
                            NavigationLink {
                                QuizSessionDetailView(session: session, attempt: index + 1)
                            } label: {
                                historyRow(session, attempt: index + 1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stats: \(groupName)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryTiles: some View {
        HStack(spacing: 12) {
            statTile(value: "\(sessions.count)", label: "quizzes")
            statTile(value: "\(averageAccuracy)%", label: "average")
            statTile(value: "\(bestAccuracy)%", label: "best")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2).bold()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var progressChart: some View {
        Chart {
            ForEach(Array(sessions.enumerated()), id: \.element.persistentModelID) { index, session in
                LineMark(
                    x: .value("Attempt", index + 1),
                    y: .value("Accuracy", accuracy(session))
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Attempt", index + 1),
                    y: .value("Accuracy", accuracy(session))
                )
                .foregroundStyle(by: .value("Mode", modeTitle(session)))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(sessions.count, 8))) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func historyRow(_ session: QuizSession, attempt: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Text("#\(attempt) · \(modeTitle(session))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(session.correctCount)/\(session.totalCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TagBadge(text: "\(accuracy(session))%", tint: tint(for: accuracy(session)))
        }
    }

    private func accuracy(_ session: QuizSession) -> Int {
        session.totalCount > 0 ? 100 * session.correctCount / session.totalCount : 0
    }

    private var averageAccuracy: Int {
        sessions.isEmpty ? 0 : sessions.map(accuracy).reduce(0, +) / sessions.count
    }

    private var bestAccuracy: Int {
        sessions.map(accuracy).max() ?? 0
    }

    private func modeTitle(_ session: QuizSession) -> String {
        QuizMode(rawValue: session.mode)?.shortTitle ?? session.mode
    }

    private func tint(for accuracy: Int) -> Color {
        switch accuracy {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }
}

struct QuizSessionDetailView: View {
    let session: QuizSession
    let attempt: Int

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: session.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Mode", value: QuizMode(rawValue: session.mode)?.title ?? session.mode)
                LabeledContent("Score", value: "\(session.correctCount) of \(session.totalCount)")
            }
            Section("Answers") {
                ForEach(session.results.sorted(by: { $0.lemma < $1.lemma }), id: \.persistentModelID) { result in
                    HStack(alignment: .top) {
                        Image(systemName: result.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isCorrect ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.lemma).font(.subheadline).bold()
                            Text(result.senseDefinition)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !result.isCorrect, !result.userAnswer.isBlank {
                                Text("You typed: \(result.userAnswer)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Attempt #\(attempt)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
