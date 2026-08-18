import SwiftUI

@main
struct PhotoUSBBackupApp: App {
    @StateObject private var backupManager = BackupManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(backupManager)
        }
    }
}
