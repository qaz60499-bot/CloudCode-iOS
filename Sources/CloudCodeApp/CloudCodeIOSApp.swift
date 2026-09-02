import SwiftUI

@main
struct CloudCodeIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CloudCodeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
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
