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
                    Text("Originals + GPS Reconcile")
                        .font(.largeTitle.bold())
                    Text("Keeps untouched originals and creates a separate GPS-merged copy only when Photos metadata disagrees with the file.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(backup.status).multilineTextAlignment(.center)

                    if backup.totalItems > 0 {
                        ProgressView(value: Double(backup.completedItems), total: Double(backup.totalItems))
                        HStack {
                            Text("\(backup.completedItems) / \(backup.totalItems) assets")
                            Spacer()
                            Text("\(backup.copiedFiles) copied")
                        }.font(.subheadline)
                        HStack {
                            Text("\(backup.originalFiles) original")
                            Spacer()
                            Text("\(backup.fallbackFiles) fallback")
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(backup.disputedFiles) disputed")
                            Spacer()
                            Text("\(backup.mergedFiles) merged")
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("\(backup.skippedFiles) skipped")
                            Spacer()
                            Text("\(backup.failedItems.count) failed")
                        }.font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Text("\(backup.adoptedFiles) adopted")
                            Spacer()
                            Text("\(backup.conflictFiles) true conflicts")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    Button {
                        Task { await backup.requestPhotoPermission() }
                    } label: {
                        Label(backup.photoAccessGranted ? "Photos Access Granted" : "Allow Photos Access",
                              systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(backup.photoAccessGranted)

                    Button { showFolderPicker = true } label: {
                        Label(backup.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder",
                              systemImage: "externaldrive")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if let destination = backup.destinationURL {
                        Text("Destination: \(destination.lastPathComponent)")
                            .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("Untouched originals preserved", systemImage: "lock.shield")
                        Label("Original resources retried", systemImage: "arrow.clockwise")
                        Label("Embedded GPS compared with Photos GPS", systemImage: "location")
                        Label("Disputed original + merged copy", systemImage: "folder")
                    }.font(.subheadline)

                    Button {
                        backup.startBackup()
                    } label: {
                        Label(backup.isRunning ? "Backup Running…" : "Start Originals Backup",
                              systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!backup.photoAccessGranted || backup.destinationURL == nil || backup.isRunning)

                    if backup.isRunning {
                        Button(role: .destructive) { backup.cancelBackup() } label: {
                            Label("Stop After Current File", systemImage: "stop.circle")
                        }
                    }

                    if !backup.failedItems.isEmpty {
                        Button { showFailures = true } label: {
                            Label("Show Failed Items", systemImage: "exclamationmark.triangle")
                        }
                    }
                }.padding()
            }
            .navigationTitle("USB Backup")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { backup.setDestination($0) }
            }
            .sheet(isPresented: $showFailures) {
                NavigationStack {
                    List(backup.failedItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename).font(.headline)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("Failed Items")
                }
            }
        }
    }
}
