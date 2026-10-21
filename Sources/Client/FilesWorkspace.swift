import SwiftUI
import UniformTypeIdentifiers
import NocturneKit

struct SharedDownload: Identifiable { let id = UUID(); let url: URL }

struct FilesWorkspace: View {
    @ObservedObject var connection: WorkspaceConnection
    let connect: () -> Void
    @StateObject private var transfer = FileTransferModel()
    @State private var files: [RemoteFile] = []
    @State private var path = ""
    @State private var loading = false
    @State private var error: String?
    @State private var importer = false
    @State private var download: SharedDownload?
    @State private var dropTarget = false
    var body: some View {
        VStack(spacing: 0) {
            if connection.state != .connected {
                ServerEmptyView(icon: "folder", title: "Less sending.\nMore doing.", detail: "Browse your computer’s shared folder and move files between devices, right here.", action: connect)
            } else if !connection.capabilities.contains("files") {
                ContentUnavailableView("Allow file sharing", systemImage: "folder.badge.gearshape", description: Text("Enable File sharing in Nocturne on your computer, then reconnect."))
            } else {
                HStack(spacing: 12) {
                    if !path.isEmpty { Button("Back", systemImage: "chevron.left") { path = path.split(separator: "/").dropLast().joined(separator: "/"); Task { await refresh() } }.labelStyle(.iconOnly).buttonStyle(NocturneGlassButtonStyle()) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(path.isEmpty ? "Shared with you" : String(path.split(separator: "/").last ?? "")).font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text(connection.name).font(.system(size: 11)).foregroundStyle(MoonStyle.secondary)
                    }
                    Spacer()
                    Button("Send file", systemImage: "plus") { importer = true }.labelStyle(.iconOnly)
                        .font(.system(size: 17)).buttonStyle(NocturneGlassButtonStyle()).controlSize(.large).disabled(transfer.activeName != nil)
                }.padding(22)
                if loading { ProgressView().padding(20) }
                if files.isEmpty && !loading {
                    ContentUnavailableView {
                        Label("A little room for your files", systemImage: "tray")
                    } description: {
                        Text("Add a file to the shared folder on your computer, or send one from this device.")
                    } actions: {
                        Button("Send a file") { importer = true }.buttonStyle(PrimaryButtonStyle()).disabled(transfer.activeName != nil)
                    }
                } else {
                    List(files) { file in
                        Button {
                            if file.isDirectory { path = file.path; Task { await refresh() } }
                            else { Task { do { download = SharedDownload(url: try await transfer.download(file, using: connection)) } catch is CancellationError {} catch { self.error = error.localizedDescription } } }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: file.isDirectory ? "folder.fill" : fileIcon(file.name))
                                    .font(.system(size: 25, weight: .light)).foregroundStyle(MoonStyle.accent).frame(width: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.name).font(.system(size: 14, weight: .medium)).foregroundStyle(MoonStyle.silver)
                                    Text(file.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.system(size: 11)).foregroundStyle(MoonStyle.secondary)
                                }
                                Spacer()
                                Image(systemName: file.isDirectory ? "chevron.right" : "arrow.down.to.line").font(.system(size: 12)).foregroundStyle(MoonStyle.secondary)
                            }.padding(.vertical, 9)
                        }.disabled(transfer.activeName != nil).listRowBackground(Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await refresh() }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(16) }
                if let name = transfer.activeName {
                    VStack(spacing: 10) {
                        HStack { Text(name).font(.caption).lineLimit(1); Spacer(); Button("Cancel") { transfer.cancel() }.font(.caption) }
                        ProgressView(value: transfer.progress)
                        HStack { Text(transfer.status); Spacer(); Text("\(Int(transfer.progress * 100))%").monospacedDigit() }.font(.caption2).foregroundStyle(MoonStyle.secondary)
                    }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(12)
                } else {
                    VStack(spacing: 8) {
                        HStack { Label("Encrypted transfer", systemImage: "lock.shield"); Spacer(); Text(transfer.status).lineLimit(1) }
                        Text("Also browse in Apple Files → Browse → Nocturne.")
                    }.font(.system(size: 10)).foregroundStyle(MoonStyle.secondary).padding(18)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background { NocturneBackdrop() }
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 20).stroke(MoonStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(10).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
                guard connection.state == .connected, connection.capabilities.contains("files"), transfer.activeName == nil, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in await upload(url) } } }; return true
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.item]) { result in
                switch result { case .success(let url): Task { await upload(url) }; case .failure(let error): self.error = error.localizedDescription }
            }
            .sheet(item: $download) { item in ShareFileView(url: item.url) { download = nil } }
            .task(id: connection.state) { if connection.state == .connected { await refresh() } else { files = []; path = "" } }
    }
    private func refresh() async {
        guard connection.capabilities.contains("files") else { return }
        loading = true; error = nil; defer { loading = false }
        do { var packet = Packet(.list); packet.path = path; files = try await connection.request(packet).files ?? [] }
        catch { self.error = error.localizedDescription }
    }
    private func upload(_ url: URL) async {
        error = nil
        do { try await transfer.upload(url, to: path, using: connection); await refresh() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func fileIcon(_ name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ["jpg", "png", "heic", "jpeg", "webp"].contains(ext) { return "photo" }
        if ["mp4", "mov"].contains(ext) { return "film" }
        if ["zip", "gz"].contains(ext) { return "doc.zipper" }
        return "doc"
    }
}

struct ShareFileView: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
