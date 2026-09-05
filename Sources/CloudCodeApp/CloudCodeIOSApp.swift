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
                    model.prepareForBackgroundTransition()
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

        // Render and commit a minimal SwiftUI shell before constructing the full runtime graph.
        // A single Task.yield() is not a first-frame guarantee: the main actor may resume before
        // CoreAnimation commits anything to screen. Keep a short launch-safe window so a device
        // crash in the heavier runtime cannot masquerade as a pre-UI/dyld failure.
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard model == nil else { return }

            let startupBreadcrumbs = StartupBreadcrumbStore()
            let startupRunID = startupBreadcrumbs.beginRun(initialStage: "app.main.enter")
            startupBreadcrumbs.append(runID: startupRunID, stage: "firstScene.visibleWindow")
            model = CloudCodeViewModel(
                startupBreadcrumbStore: startupBreadcrumbs,
                startupRunID: startupRunID
            )
        }
    }
}
