import SwiftUI
import CloudCodeCore

@main
struct CloudCodeIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launcher = CloudCodeAppLauncher()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = launcher.model {
                    ContentView(model: model)
                        .task {
                            model.bootstrap()
                        }
                } else {
                    ProgressView("正在启动 Cloud Code…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            }
            .onAppear {
                launcher.startIfNeeded()
            }
            .onChange(of: scenePhase) { phase in
                guard let model = launcher.model else { return }
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

@MainActor
private final class CloudCodeAppLauncher: ObservableObject {
    @Published private(set) var model: CloudCodeViewModel?
    private var didStart = false

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        // Render the minimal SwiftUI shell before constructing the full runtime graph.
        // This keeps filesystem caches, AVFoundation/Speech, CFNetwork, private adapters,
        // and recovery state away from the process' pre-first-frame launch boundary.
        Task { @MainActor in
            await Task.yield()
            let startupBreadcrumbs = StartupBreadcrumbStore()
            let startupRunID = startupBreadcrumbs.beginRun(initialStage: "app.main.enter")
            startupBreadcrumbs.append(runID: startupRunID, stage: "firstScene.rendered")
            model = CloudCodeViewModel(
                startupBreadcrumbStore: startupBreadcrumbs,
                startupRunID: startupRunID
            )
        }
    }
}
