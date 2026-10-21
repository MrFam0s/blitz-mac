// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import Foundation
import os

private let gestureOverlayLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "GestureVisualization")

@MainActor
@Observable
final class GestureVisualizationSocketService {
    private(set) var liveEvents: [GestureVisualizationEvent] = []

    private let socketURL: URL
    private let ioQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var recentEventIDs: Set<String> = []

    init(
        socketURL: URL = BlitzPaths.gestureEventsSocket,
        ioQueue: DispatchQueue = DispatchQueue(label: "org.amosystems.BlitzNeo.gesture-events", qos: .userInteractive),
        autostart: Bool = true
    ) {
        self.socketURL = socketURL
        self.ioQueue = ioQueue
        if autostart {
            start()
        }
    }

    func start() {
        guard readSource == nil else { return }

        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: socketURL)

            let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                throw SocketError.socketCreationFailed(code: errno)
            }

            var address = try makeSocketAddress()
            let addressLength = socklen_t(address.sun_len)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, addressLength)
                }
            }
            guard bindResult == 0 else {
                let code = errno
                Darwin.close(fd)
                throw SocketError.bindFailed(code: code)
            }

            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }

            _ = chmod(socketURL.path, mode_t(0o600))

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.drainSocket(fd: fd)
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()

            socketFD = fd
            readSource = source
            gestureOverlayLogger.info("Listening for gesture visualization events on \(self.socketURL.path, privacy: .public)")
        } catch {
            gestureOverlayLogger.error("Failed to start gesture visualization socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    func tearDown() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        recentEventIDs.removeAll()
        liveEvents.removeAll()
        try? FileManager.default.removeItem(at: socketURL)
    }

    func events(for deviceID: String?) -> [GestureVisualizationEvent] {
        guard let deviceID, !deviceID.isEmpty else { return [] }
        return liveEvents.filter { $0.target.deviceId == deviceID }
    }

    private nonisolated func drainSocket(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let decoder = JSONDecoder()

        while true {
            let received = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if received > 0 {
                let data = Data(buffer.prefix(received))
                if let event = GestureVisualizationEvent.decodeLiveEvent(from: data, decoder: decoder) {
                    Task { @MainActor [weak self] in
                        self?.handle(event)
                    }
                }
                continue
            }

            if received == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            gestureOverlayLogger.error("recv() failed for gesture visualization socket: \(errno)")
            return
        }
    }

    private func handle(_ event: GestureVisualizationEvent) {
        guard event.isRenderableInBlitz else { return }
        guard !recentEventIDs.contains(event.id) else { return }

        recentEventIDs.insert(event.id)
        liveEvents.append(event)

        let eventID = event.id
        DispatchQueue.main.asyncAfter(deadline: .now() + event.expiryInterval) { [weak self] in
            self?.liveEvents.removeAll { $0.id == eventID }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.recentEventIDs.remove(eventID)
        }
    }

    private func makeSocketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        let path = socketURL.path
        let pathLength = path.utf8.count
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1

        guard pathLength <= maxPathLength else {
            throw SocketError.invalidSocketPath
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withCString { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: pathLength + 1))
            }
        }
        return address
    }

    enum SocketError: LocalizedError {
        case socketCreationFailed(code: Int32)
        case bindFailed(code: Int32)
        case invalidSocketPath

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed(let code):
                return "socket() failed with errno \(code)"
            case .bindFailed(let code):
                return "bind() failed with errno \(code)"
            case .invalidSocketPath:
                return "Gesture visualization socket path is too long"
            }
        }
    }
}
