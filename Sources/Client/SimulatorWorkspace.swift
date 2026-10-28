import SwiftUI
import NocturneKit

@MainActor
final class SimulatorPreviewModel: ObservableObject {
    @Published private(set) var devices: [RemoteSimulator] = []
    @Published private(set) var image: UIImage?
    @Published private(set) var dimensions = ""
    @Published private(set) var selected: String?
    @Published private(set) var busy = false
    @Published var error: String?
    private let connection: WorkspaceConnection
    private var lease: String?
    private var epoch = UUID()
    private var frames: Task<Void, Never>?
    init(connection: WorkspaceConnection) { self.connection = connection }
    func load() async {
        guard !busy, connection.state == .connected else { return }
        let generation = epoch; busy = true; error = nil
        defer { if epoch == generation { busy = false } }
        do {
            let reply = try await connection.request(Packet(.simulatorList))
            guard epoch == generation else { return }
            guard let devices = reply.simulators, devices.count <= SimulatorStreaming.maximumDevices,
                  Set(devices.map(\.id)).count == devices.count else { throw NocturneError.invalidFrame }
            self.devices = devices
        } catch { if epoch == generation { self.error = error.localizedDescription } }
    }
    func start(_ device: RemoteSimulator) async {
        guard !busy else { return }
        let previous = lease
        stop(release: false); let generation = epoch; busy = true; error = nil
        defer { if epoch == generation { busy = false } }
        do {
            if let previous {
                var close = Packet(.simulatorClose); close.sessionID = previous
                _ = try await connection.request(close)
                guard epoch == generation else { return }
            }
            var request = Packet(.simulatorOpen); request.simulatorID = device.id
            let reply = try await connection.request(request)
            guard let id = reply.sessionID else { throw NocturneError.invalidFrame }
            guard reply.simulatorID == device.id else { close(id); throw NocturneError.invalidFrame }
            guard epoch == generation else { close(id); return }
            lease = id; selected = device.id
            frames = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled && self.epoch == generation {
                        var packet = Packet(.simulatorFrame); packet.sessionID = id
                        let reply = try await self.connection.request(packet)
                        guard !Task.isCancelled, self.epoch == generation else { return }
                        guard reply.sessionID == id, reply.simulatorID == device.id,
                              let frame = reply.simulatorFrame, frame.isValid,
                              let image = UIImage(data: frame.jpeg) else { throw NocturneError.invalidFrame }
                        self.image = image
                        self.dimensions = "\(frame.pixelWidth) × \(frame.pixelHeight) pixels"
                        // Pull only after decode: no queued frames or unbounded network backlog.
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                } catch {
                    guard self.epoch == generation else { return }
                    self.stop(); self.error = error.localizedDescription
                }
            }
        } catch { if epoch == generation { stop(); self.error = error.localizedDescription } }
    }
    func stop(release: Bool = true) {
        epoch = UUID(); frames?.cancel(); frames = nil; busy = false
        if release, let lease { close(lease) }
        lease = nil; selected = nil; image = nil; dimensions = ""
    }
    func reset() { stop(); devices = []; error = nil }
    private func close(_ id: String) {
        let connection = connection
        Task { var packet = Packet(.simulatorClose); packet.sessionID = id; _ = try? await connection.request(packet) }
    }
}

struct SimulatorWorkspace: View {
    @ObservedObject var connection: WorkspaceConnection
    @StateObject private var model: SimulatorPreviewModel
    @Environment(\.scenePhase) private var scenePhase
    init(connection: WorkspaceConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: SimulatorPreviewModel(connection: connection))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Simulator preview").font(.title2.bold())
                Text("View a running iOS simulator directly from your Mac. Touch control and remote rotation are unavailable. Start or rotate simulators in Xcode on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                if connection.state != .connected {
                    Text("Connect to your Mac to view its simulators.")
                } else if !connection.capabilities.contains(SimulatorStreaming.capability) {
                    Text("Enable Simulator preview in Nocturne on your Mac and reconnect. Xcode is required.")
                } else {
                    HStack {
                        Button("Refresh devices", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.busy)
                        Spacer()
                        Button("Stop preview", role: .cancel) { model.stop() }.disabled(model.selected == nil && !model.busy)
                    }
                    if model.busy { ProgressView() }
                    if let error = model.error { Text(error).foregroundStyle(.secondary) }
                    ForEach(model.devices) { device in
                        Button { Task { await model.start(device) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text("\(device.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")) · \(device.state)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected == device.id { Image(systemName: "checkmark") }
                            }
                        }.disabled(!device.isBooted || model.busy)
                    }
                    if model.devices.isEmpty && !model.busy { Text("No available iOS simulators. Manage simulators in Xcode on your Mac.").foregroundStyle(.secondary) }
                    if let image = model.image {
                        Text(model.dimensions).font(.caption.monospacedDigit())
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 900)
                            .accessibilityLabel("Simulator display, preview only")
                            .allowsHitTesting(false)
                    }
                }
            }.padding()
        }
        .navigationTitle("Simulator")
        .task(id: connection.state) {
            model.reset()
            if connection.state == .connected && connection.capabilities.contains(SimulatorStreaming.capability) { await model.load() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.reset() }
    }
}
