import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var backup: BackupManager
    @State private var showFolderPicker = false
    @State private var showFailures = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 64))

                    Text("Originals Backup")
                        .font(.largeTitle.bold())

                    Text("Copies unmodified originals from Photos to an external USB/SSD.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text(backup.status)
                        .multilineTextAlignment(.center)

                    if backup.totalItems > 0 {
                        ProgressView(
                            value: Double(backup.completedItems),
                            total: Double(backup.totalItems)
                        )

                        HStack {
                            Text("\(backup.completedItems) / \(backup.totalItems) assets")
                            Spacer()
                            Text("\(backup.copiedFiles) files copied")
                        }
                        .font(.subheadline)

                        HStack {
                            Text("\(backup.skippedFiles) skipped")
                            Spacer()
                            Text("\(backup.failedItems.count) failed")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    Button {
                        Task {
                            await backup.requestPhotoPermission()
                        }
                    } label: {
                        Label(
                            backup.photoAccessGranted ? "Photos Access Granted" : "Allow Photos Access",
                            systemImage: "photo.on.rectangle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(backup.photoAccessGranted)

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label(
                            backup.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder",
                            systemImage: "externaldrive"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if let destination = backup.destinationURL {
                        VStack(spacing: 4) {
                            Text("Destination")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(destination.lastPathComponent)
                                .font(.headline)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Unmodified originals only", systemImage: "checkmark.seal.fill")
                        Label("Includes Live Photo paired video", systemImage: "livephoto")
                        Label("Downloads iCloud originals when needed", systemImage: "icloud.and.arrow.down")
                        Label("Uses .partial files for safe resume", systemImage: "arrow.clockwise")
                        Label("Verifies completed files by size", systemImage: "checkmark.shield")
                    }
                    .font(.subheadline)

                    Button {
                        backup.startBackup()
                    } label: {
                        Label(
                            backup.isRunning ? "Backup Running…" : "Start Originals Backup",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !backup.photoAccessGranted ||
                        backup.destinationURL == nil ||
                        backup.isRunning
                    )

                    if backup.isRunning {
                        Button(role: .destructive) {
                            backup.cancelBackup()
                        } label: {
                            Label("Stop After Current File", systemImage: "stop.circle")
                        }
                    }

                    if !backup.failedItems.isEmpty {
                        Button {
                            showFailures = true
                        } label: {
                            Label("Show Failed Items", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("USB Backup")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    backup.setDestination(url)
                }
            }
            .sheet(isPresented: $showFailures) {
                NavigationStack {
                    List(backup.failedItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename)
                                .font(.headline)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Failed Items")
                }
            }
        }
    }
}
