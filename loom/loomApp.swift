import SwiftUI

@main
struct loomApp: App {
    var body: some Scene {
        MenuBarExtra("FreeLum", systemImage: "video.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
