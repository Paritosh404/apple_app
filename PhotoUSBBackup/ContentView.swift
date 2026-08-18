import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var backup: BackupManager
    @State private var showFolderPicker = false
    @State private var showFailures = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 60))

                    Text("Originals + GPS Backup")
                        .font(.largeTitle.bold())

                    Text("Copies the best available original resource without modifying it, and writes Photos-library GPS/date metadata to XMP sidecars.")
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
                            Text("\(backup.copiedFiles) files")
                        }
                        .font(.subheadline)

                        HStack {
                            Text("\(backup.originalFiles) original")
                            Spacer()
                            Text("\(backup.fallbackFiles) fallback")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                        Task { await backup.requestPhotoPermission() }
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
                        VStack(spacing: 3) {
                            Text("Destination")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(destination.lastPathComponent)
                                .font(.headline)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("Original .photo / .video first", systemImage: "checkmark.seal.fill")
                        Label("3 retries for PhotoKit resource errors", systemImage: "arrow.clockwise")
                        Label("Streaming requestData fallback", systemImage: "arrow.down.doc")
                        Label("Live Photo still + paired video", systemImage: "livephoto")
                        Label("GPS/date saved to .xmp sidecars", systemImage: "location")
                        Label("Original file bytes remain untouched", systemImage: "lock.shield")
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
                            Text(item.filename).font(.headline)
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
