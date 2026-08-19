import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: AlbumCopyManager
    @State private var showDestinationPicker = false
    @State private var showAlbumPicker = false
    @State private var showFailures = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 60))

                    Text("Album Copy")
                        .font(.largeTitle.bold())

                    Text("Copy a Photos album/folder hierarchy to an external USB/SSD.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text(manager.status)
                        .multilineTextAlignment(.center)

                    if manager.stats.totalAssets > 0 {
                        ProgressView(value: Double(manager.stats.processedAssets), total: Double(manager.stats.totalAssets))
                        HStack {
                            Text("\(manager.stats.processedAssets) / \(manager.stats.totalAssets) assets")
                            Spacer()
                            Text("\(manager.stats.copiedFiles) copied")
                        }
                        .font(.subheadline)
                        HStack {
                            Text("\(manager.stats.skippedFiles) skipped")
                            Spacer()
                            Text("\(manager.stats.failedFiles) failed")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    Button {
                        Task { await manager.requestPhotoPermission() }
                    } label: {
                        Label(manager.photoAccessGranted ? "Photos Access Granted" : "Allow Photos Access", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.photoAccessGranted)

                    Button {
                        manager.refreshPhotoTree()
                        showAlbumPicker = true
                    } label: {
                        Label(manager.selectedSource == nil ? "Choose Album / Folder" : "Change Album / Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!manager.photoAccessGranted)

                    if let selected = manager.selectedSource {
                        Text("Source: \(selected.title)").font(.headline)
                    }

                    Button {
                        showDestinationPicker = true
                    } label: {
                        Label(manager.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder", systemImage: "externaldrive")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if let destination = manager.destinationURL {
                        Text("Destination: \(destination.lastPathComponent)").font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("Recreates Photos folder/album structure", systemImage: "folder.fill")
                        Label("Copies current full-size Photos rendition", systemImage: "photo")
                        Label("Simple existing-file skip", systemImage: "forward.fill")
                        Label("Uses .partial files for safe resume", systemImage: "arrow.clockwise")
                        Label("Processes one asset at a time", systemImage: "memorychip")
                    }
                    .font(.subheadline)

                    Button {
                        manager.startCopy()
                    } label: {
                        Label(manager.isRunning ? "Copy Running…" : "Start Album Copy", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.selectedSource == nil || manager.destinationURL == nil || manager.isRunning)

                    if manager.isRunning {
                        Button(role: .destructive) {
                            manager.stopCopy()
                        } label: {
                            Label("Stop After Current File", systemImage: "stop.circle")
                        }
                    }

                    if !manager.failures.isEmpty {
                        Button { showFailures = true } label: {
                            Label("Show Recent Failures", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("USB Album Copy")
            .sheet(isPresented: $showDestinationPicker) {
                FolderPicker { manager.setDestination($0) }
            }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumPickerView().environmentObject(manager)
            }
            .sheet(isPresented: $showFailures) {
                NavigationStack {
                    List(manager.failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.path).font(.headline)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Recent Failures")
                }
            }
        }
    }
}
