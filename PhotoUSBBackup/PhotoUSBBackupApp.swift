import SwiftUI
import UIKit

final class PhotoUSBAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundUploadCoordinator.shared.setSystemCompletionHandler(completionHandler)
    }
}

@main
struct PhotoUSBBackupApp: App {
    @UIApplicationDelegateAdaptor(PhotoUSBAppDelegate.self) private var appDelegate
    @StateObject private var manager = AlbumCopyManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
