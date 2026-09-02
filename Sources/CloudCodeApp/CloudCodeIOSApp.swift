import SwiftUI

@main
struct CloudCodeIOSApp: App {
    @StateObject private var model = CloudCodeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    model.bootstrap()
                }
        }
    }
}
