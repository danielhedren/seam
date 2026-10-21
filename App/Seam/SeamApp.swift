import Features
import SwiftUI

@main
struct SeamApp: App {
    /// Held here so the settings and store are built once, not on every body evaluation.
    @State private var services = SeamServices.live()

    var body: some Scene {
        SeamScenes(services: services)
    }
}
