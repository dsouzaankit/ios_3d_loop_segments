import Foundation
import Network

/// Shows whether export traffic will use cellular vs Wi‑Fi (hotspot not required).
@MainActor
final class NetworkPathMonitor: ObservableObject {
    @Published private(set) var interfaceLabel = "Checking…"
    @Published private(set) var usesCellular = false
    @Published private(set) var usesWiFi = false
    @Published private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.loopsegments.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.apply(path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func apply(_ path: NWPath) {
        usesCellular = path.usesInterfaceType(.cellular)
        usesWiFi = path.usesInterfaceType(.wifi)
        isExpensive = path.isExpensive

        if path.status != .satisfied {
            interfaceLabel = "No internet"
        } else if usesCellular && !usesWiFi {
            interfaceLabel = "Cellular (OK for pCloud — no hotspot needed)"
        } else if usesWiFi {
            interfaceLabel = "Wi‑Fi"
        } else {
            interfaceLabel = "Online"
        }
    }
}
