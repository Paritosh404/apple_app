import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: AlbumCopyManager
    @State private var showDestinationPicker = false
    @State private var showAlbumPicker = false
    @State private var showFailures = false
    @State private var showQRScanner = false
    @State private var showTransferScreen = false

    private var completeOnPC: Int {
        manager.stats.copiedFiles + manager.stats.skippedFiles
    }

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
                    Text(manager.status)
                        .multilineTextAlignment(.center)
                        .lineLimit(3, reservesSpace: true)
                    if manager.stats.totalAssets > 0 {
                        ProgressView(value: Double(completeOnPC), total: Double(manager.stats.totalAssets))
                        HStack {
                            Text("\(completeOnPC) / \(manager.stats.totalAssets) complete on PC")
                            Spacer()
                            if manager.uploadsPaused { Text("Paused") }
                            else if manager.transferMode == .wifi { Text("\(manager.pendingUploads) queued") }
                            else { Text("\(manager.stats.copiedFiles) copied") }
                        }.font(.subheadline)
                        if manager.transferMode == .wifi {
                            HStack {
                                Text("\(manager.stats.processedAssets) prepared")
                                Spacer()
                                Text("\(manager.stats.copiedFiles) newly saved")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
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
                            Button { showQRScanner = true } label: {
                                Label("Scan Receiver QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                            TextField("PC IP address", text: $manager.receiverHost).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Port", text: $manager.receiverPort).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                            Text("Example: 192.168.1.20 : 8765").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        manager.startCopy()
                        showTransferScreen = true
                    } label: {
                        Label(manager.primaryActionTitle, systemImage: manager.pendingUploads > 0 && !manager.isPreparing ? "arrow.up.circle.fill" : "arrow.right.circle.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(!manager.canStart)
                    if manager.isRunning {
                        Button { showTransferScreen = true } label: {
                            Label("Show Transfer Progress", systemImage: "chart.bar.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                    if !manager.failures.isEmpty { Button { showFailures = true } label: { Label("Show Recent Failures", systemImage: "exclamationmark.triangle") } }
                }.padding()
            }
            .navigationTitle("USB / Wi-Fi Copy")
            .sheet(isPresented: $showDestinationPicker) { FolderPicker { url in manager.setDestination(url) } }
            .sheet(isPresented: $showAlbumPicker) { AlbumPickerView().environmentObject(manager) }
            .sheet(isPresented: $showQRScanner) {
                NavigationStack {
                    ZStack {
                        QRScannerView { code in
                            showQRScanner = false
                            Task { await manager.connectFromQRCode(code) }
                        }.ignoresSafeArea()
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 250, height: 250)
                    }
                    .navigationTitle("Scan Receiver QR")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showQRScanner = false } }
                    }
                }
            }
            .sheet(isPresented: $showFailures) {
                NavigationStack { List(manager.failures) { failure in VStack(alignment: .leading, spacing: 4) { Text(failure.path).font(.headline); Text(failure.reason).font(.caption).foregroundStyle(.secondary) } }.navigationTitle("Recent Failures") }
            }
            .fullScreenCover(isPresented: $showTransferScreen) {
                TransferProgressView(isPresented: $showTransferScreen)
                    .environmentObject(manager)
            }
            .onAppear {
                if manager.isRunning { showTransferScreen = true }
            }
            .onChange(of: manager.isRunning) { _, running in
                if running { showTransferScreen = true }
            }
        }
    }
}

private struct TransferProgressView: View {
    @EnvironmentObject private var manager: AlbumCopyManager
    @Binding var isPresented: Bool
    @State private var showFailures = false
    @State private var showStopConfirmation = false

    private var finishedCount: Int {
        manager.stats.copiedFiles + manager.stats.skippedFiles
    }

    private var overallProgress: Double {
        guard manager.stats.totalAssets > 0 else { return 0 }
        return min(1, Double(finishedCount) / Double(manager.stats.totalAssets))
    }

    private var fileProgress: Double {
        guard manager.currentBytesExpected > 0 else { return 0 }
        return min(1, Double(manager.currentBytesSent) / Double(manager.currentBytesExpected))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle().fill(.blue.opacity(0.12)).frame(width: 112, height: 112)
                        Image(systemName: manager.transferMode == .wifi ? "wifi.circle.fill" : "externaldrive.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                    }

                    VStack(spacing: 8) {
                        Text(manager.isRunning ? "Transfer in Progress" : "Transfer Summary")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(manager.status)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
                            .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Complete on PC").font(.headline)
                            Spacer()
                            Text("\(finishedCount) of \(manager.stats.totalAssets)")
                                .font(.subheadline.monospacedDigit())
                        }
                        ProgressView(value: overallProgress)
                            .tint(.blue)
                            .scaleEffect(x: 1, y: 1.8)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    if manager.isPreparing {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Preparing photos and videos", systemImage: "photo.stack")
                                .font(.headline)
                            ProgressView(
                                value: Double(manager.stats.processedAssets),
                                total: Double(max(manager.stats.totalAssets, 1))
                            )
                            Text("\(manager.stats.processedAssets) prepared • \(manager.pendingUploads) queued")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if manager.isRunning || manager.stats.totalAssets > 0 || !manager.currentItem.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current file").font(.caption).foregroundStyle(.secondary)
                            Text(manager.currentItem.isEmpty ? "Preparing next file…" : manager.currentItem)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                            if manager.currentBytesExpected > 0 {
                                ProgressView(value: fileProgress).tint(.green)
                                Text("\(formattedBytes(manager.currentBytesSent)) of \(formattedBytes(manager.currentBytesExpected))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metric("Saved", manager.stats.copiedFiles, "checkmark.circle.fill", .green)
                        metric("Queued", manager.pendingUploads, "clock.arrow.circlepath", .blue)
                        metric("Skipped", manager.stats.skippedFiles, "forward.fill", .orange)
                        metric("Failed", manager.stats.failedFiles, "exclamationmark.triangle.fill", .red)
                    }

                    if manager.uploadsPaused {
                        Label(
                            "All preparation and queued uploads are paused. Staged files are preserved until you resume or stop the transfer.",
                            systemImage: "pause.circle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    } else if manager.transferMode == .wifi && manager.pendingUploads > 0 {
                        Label(
                            "Uploads can continue when you open another app or lock the screen. Do not swipe Album Copy away from the app switcher.",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    }

                    if manager.isRunning {
                        Button {
                            if manager.uploadsPaused { manager.resumeAllOperations() }
                            else { manager.pauseAllOperations() }
                        } label: {
                            Label(
                                manager.uploadsPaused ? "Resume All Operations" : "Pause All Operations",
                                systemImage: manager.uploadsPaused ? "play.circle.fill" : "pause.circle.fill"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) { showStopConfirmation = true } label: {
                            Label("Stop Transfer and Clear Queue", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !manager.failures.isEmpty {
                        Button { showFailures = true } label: {
                            Label("Show Recent Failures", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button { isPresented = false } label: {
                        Label(manager.isRunning ? "Hide Progress Screen" : "Done", systemImage: "chevron.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
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
            .confirmationDialog(
                "Stop this transfer?",
                isPresented: $showStopConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop and Clear Queue", role: .destructive) {
                    manager.stopAllOperations()
                }
                Button("Keep Transfer", role: .cancel) { }
            } message: {
                Text("Queued uploads will be cancelled and their staged files removed. Files already saved on the PC will not be deleted.")
            }
        }
    }

    private func metric(_ title: String, _ value: Int, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text("\(value)").font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
