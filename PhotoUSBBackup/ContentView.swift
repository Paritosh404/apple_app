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
                    Image(systemName: manager.transferMode == .wifi ? "wifi" : "externaldrive")
                        .font(.system(size: 60))
                    Text("Album Copy").font(.largeTitle.bold())
                    Picker("Transfer Mode", selection: $manager.transferMode) {
                        ForEach(TransferMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text(manager.status).multilineTextAlignment(.center)
                    if manager.stats.totalAssets > 0 {
                        ProgressView(value: Double(manager.stats.processedAssets), total: Double(manager.stats.totalAssets))
                        HStack { Text("\(manager.stats.processedAssets) / \(manager.stats.totalAssets)"); Spacer(); Text("\(manager.stats.copiedFiles) copied") }.font(.subheadline)
                        HStack { Text("\(manager.stats.skippedFiles) skipped"); Spacer(); Text("\(manager.stats.failedFiles) failed") }.font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button { Task { await manager.requestPhotoPermission() } } label: {
                        Label(manager.photoAccessGranted ? "Photos Access Granted" : "Allow Photos Access", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(manager.photoAccessGranted)
                    Button { manager.refreshPhotoTree(); showAlbumPicker = true } label: {
                        Label(manager.selectedSource == nil ? "Choose Album / Folder" : "Change Album / Folder", systemImage: "folder").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(!manager.photoAccessGranted)
                    if let source = manager.selectedSource { Text("Source: \(source.title)").font(.headline) }
                    if manager.transferMode == .usb {
                        Button { showDestinationPicker = true } label: {
                            Label(manager.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder", systemImage: "externaldrive").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                        if let destination = manager.destinationURL { Text("Destination: \(destination.lastPathComponent)").font(.headline) }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("PC IP address", text: $manager.receiverHost).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Port", text: $manager.receiverPort).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                            Text("Example: 192.168.1.20 : 8765").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { manager.startCopy() } label: {
                        Label(manager.isRunning ? "Transfer Running…" : "Start Transfer", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(!manager.canStart)
                    if manager.isRunning { Button(role: .destructive) { manager.stopCopy() } label: { Label("Stop After Current File", systemImage: "stop.circle") } }
                    if !manager.failures.isEmpty { Button { showFailures = true } label: { Label("Show Recent Failures", systemImage: "exclamationmark.triangle") } }
                }.padding()
            }
            .navigationTitle("USB / Wi-Fi Copy")
            .sheet(isPresented: $showDestinationPicker) { FolderPicker { url in manager.setDestination(url) } }
            .sheet(isPresented: $showAlbumPicker) { AlbumPickerView().environmentObject(manager) }
            .sheet(isPresented: $showFailures) {
                NavigationStack { List(manager.failures) { failure in VStack(alignment: .leading, spacing: 4) { Text(failure.path).font(.headline); Text(failure.reason).font(.caption).foregroundStyle(.secondary) } }.navigationTitle("Recent Failures") }
            }
        }
    }
}
