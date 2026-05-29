import SwiftUI
import SwiftData
import Charts

struct MetricsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager

    var body: some View {
        VStack {
            MetricsContent(modelContext: modelContext)
        }
        .background(Color(.controlBackgroundColor))
    }
}
