import SwiftUI

@main
struct DiskAnalyzerApp: App {
    var body: some Scene {
        WindowGroup("Disk Analyzer") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        // Standard titlebar only. No .unified toolbar region — it pulls our
        // custom toolbar under the title bar's vibrancy layer and washes out
        // the content.
        .windowStyle(.titleBar)
    }
}
