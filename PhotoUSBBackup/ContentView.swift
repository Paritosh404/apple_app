import SwiftUI

struct ContentView: View {
    @EnvironmentObject var backup: BackupManager
    @State private var showFolderPicker = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 60))
                    Text("Originals Backup").font(.largeTitle.bold())
                    Text("Copies unmodified originals from Photos to an external USB/SSD.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text(backup.status).multilineTextAlignment(.center)
                    if backup.totalItems > 0 {
                        ProgressView(value: Double(backup.completedItems), total: Double(backup.totalItems))
                        Text("\(backup.completedItems) / \(backup.totalItems) assets • \(backup.copiedFiles) files copied • \(backup.skippedFiles) skipped • \(backup.failedItems.count) failed")
                            .font(.caption).multilineTextAlignment(.center)
                    }
                    Button(backup.photoAccessGranted ? "Photos Access Granted" : "Allow Photos Access") {
                        Task { await backup.requestPhotoPermission() }
                    }.buttonStyle(.borderedProminent).disabled(backup.photoAccessGranted)
                    Button(backup.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder") { showFolderPicker = true }
                        .buttonStyle(.bordered)
                    if let u = backup.destinationURL { Text("Destination: \(u.lastPathComponent)").font(.caption) }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Unmodified originals only", systemImage: "checkmark.seal")
                        Label("Live Photo paired video included", systemImage: "livephoto")
                        Label("iCloud originals allowed", systemImage: "icloud.and.arrow.down")
                        Label(".partial files + resume manifest", systemImage: "arrow.clockwise")
                        Label("Final size verification", systemImage: "checkmark.shield")
                    }.font(.subheadline)
                    Button(backup.isRunning ? "Backup Running…" : "Start Originals Backup") { backup.startBackup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!backup.photoAccessGranted || backup.destinationURL == nil || backup.isRunning)
                    if backup.isRunning {
                        Button("Stop After Current File", role: .destructive) { backup.cancelBackup() }
                    }
                }.padding()
            }.navigationTitle("USB Backup")
            .sheet(isPresented: $showFolderPicker) { FolderPicker { backup.setDestination($0) } }
        }
    }
}
