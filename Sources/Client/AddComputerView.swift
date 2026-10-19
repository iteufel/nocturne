import SwiftUI
import VisionKit
import AVFoundation
import NocturneKit

struct AddComputerView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = false
    @State private var scannedInvitation: String?
    @State private var scannerError: String?
    init(model: ClientModel) { self.model = model; connection = model.server }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("Add a host").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("Open Nocturne Server on your Mac, start the server, and choose “Pair a device.” The QR code sets up your workspace and screen sharing.")
                        .font(.subheadline).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    MoonPanel {
                        HStack(spacing: 16) {
                            Label("Stream", systemImage: "display")
                            Label("Terminal", systemImage: "terminal")
                            Label("Files", systemImage: "folder")
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(MoonStyle.accent)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Scan to pair").font(.headline)
                        Button { Task { await openScanner() } } label: {
                            HStack {
                                if connection.state == .connecting { ProgressView().tint(MoonStyle.ink) }
                                Label(connection.state == .connecting ? "Connecting…" : "Scan QR code", systemImage: "qrcode.viewfinder")
                            }
                        }.buttonStyle(PrimaryButtonStyle())
                            .disabled(!DataScannerViewController.isSupported || connection.state == .connecting || model.busy)
                            .accessibilityIdentifier("scanPairingQR")
                        if !DataScannerViewController.isSupported {
                            Text("QR pairing requires a supported iPhone or iPad camera.").font(.caption).foregroundStyle(MoonStyle.secondary)
                        }
                        if let scannerError { Text(scannerError).font(.caption).foregroundStyle(.orange) }
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button("Open camera settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if let error = model.error ?? connection.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    if !model.pairedServers.servers.isEmpty {
                        Text("Your other hosts stay paired. Manage them in Settings → Paired hosts.").font(.caption).foregroundStyle(MoonStyle.secondary)
                    }
                    Text("Only scan the QR code shown by your Mac. It pairs one device and expires after five minutes. Terminal and file access are controlled on your Mac.").font(.caption).foregroundStyle(MoonStyle.secondary)
                }.padding(24)
            }.background { NocturneBackdrop() }.navigationTitle("Add host").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(MoonStyle.accent)
            .sheet(isPresented: $scanner, onDismiss: pairScannedInvitation) { QRScanner { result in
                scanner = false
                switch result { case .success(let text): scannedInvitation = text; case .failure(let error): scannerError = error.localizedDescription }
            }.ignoresSafeArea() }
    }
    private func openScanner() async {
        scannerError = nil; model.error = nil
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard DataScannerViewController.isAvailable else {
            scannerError = "The camera is unavailable. Allow camera access in Settings and try scanning again."; return
        }
        scanner = true
    }
    private func pairScannedInvitation() {
        guard let text = scannedInvitation else { return }
        scannedInvitation = nil
        Task { await model.pairScannedServer(text) }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let completion: (Result<String, Error>) -> Void
        var finished = false
        init(completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.hasPrefix("nocturne://pair") {
                    finished = true; dataScanner.stopScanning(); completion(.success(value)); return
                }
            }
        }
    }
}
