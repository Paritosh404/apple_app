import SwiftUI

@main
struct PhotoUSBBackupApp: App {
    @StateObject private var backup = BackupManager.shared
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(backup) }
    }
}
