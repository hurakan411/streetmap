#if WIDGET_LAYOUT_STUDY
import SwiftUI
import WidgetKit

// Standalone, local-only visual QA. Does not read or modify app preferences.
@main
struct RecordingWidgetLayoutStudy: App {
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 18) {
                    sample(active: true, language: "japanese", theme: "editorialGlass")
                    sample(active: false, language: "japanese", theme: "paperAtlas")
                    sample(active: true, language: "english", theme: "midnightPulse")
                }.padding(20)
            }.background(Color(white: 0.88))
        }
    }

    private func sample(active: Bool, language: String, theme: String) -> some View {
        let state = RecordingWidgetState(recordingMode: active ? .background : .off,
            movementMode: .all, authorization: 3, isCollecting: active,
            isConfigured: true, language: language, theme: theme)
        let entry = RecordingEntry(date: .now, state: state)
        let color = theme == "midnightPulse" ? Color(red: 0.035, green: 0.085, blue: 0.13)
            : theme == "paperAtlas" ? Color(red: 0.96, green: 0.94, blue: 0.90)
            : Color(red: 0.96, green: 0.97, blue: 0.98)
        return VStack(spacing: 10) {
            RecordingWidgetView(entry: entry, previewFamily: .systemSmall)
                .padding(16).frame(width: 158, height: 158)
                .background(color, in: RoundedRectangle(cornerRadius: 22))
            RecordingWidgetView(entry: entry, previewFamily: .systemMedium)
                .padding(16).frame(width: 338, height: 158)
                .background(color, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
#endif
