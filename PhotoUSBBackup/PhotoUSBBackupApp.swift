import SwiftUI

@main
struct PhotoUSBBackupApp: App {
    @StateObject private var manager = AlbumCopyManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
