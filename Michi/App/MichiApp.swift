import SwiftUI

extension Notification.Name {
    static let michiRestartOnboarding = Notification.Name("michiRestartOnboarding")
}

@main
struct MichiApp: App {
    @StateObject private var store = AppStore()
    // 新しいオンボーディングを既存の開発端末でも一度だけ表示する。
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    MainMapView()
                        .environmentObject(store)
                } else {
                    OnboardingView(isComplete: $hasCompletedOnboarding)
                        .environmentObject(store)
                }
            }
            .environment(\.locale, Locale(identifier: store.appLanguage.localeIdentifier))
            .preferredColorScheme(store.theme.prefersDarkMap ? .dark : .light)
            .onReceive(NotificationCenter.default.publisher(for: .michiRestartOnboarding)) { _ in
                hasCompletedOnboarding = false
            }
        }
    }
}
