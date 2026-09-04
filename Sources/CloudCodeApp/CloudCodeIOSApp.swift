import SwiftUI
import CloudCodeCore

@main
struct CloudCodeIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CloudCodeViewModel

    init() {
        let startupBreadcrumbs = StartupBreadcrumbStore()
        let startupRunID = startupBreadcrumbs.beginRun(initialStage: "app.main.enter")
        _model = StateObject(wrappedValue: CloudCodeViewModel(
            startupBreadcrumbStore: startupBreadcrumbs,
            startupRunID: startupRunID
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    model.recordStartupBreadcrumb("firstScene.rendered")
                }
                .task {
                    model.bootstrap()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        model.suspendForBackground()
                    case .active:
                        model.refreshAfterForeground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
