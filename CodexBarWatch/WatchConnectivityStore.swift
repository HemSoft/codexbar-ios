import Foundation
import WatchConnectivity

@MainActor
final class WatchDashboardStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchDashboardSnapshot?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var decodingError: String?

    private static let persistedSnapshotKey = "watch.dashboard.last-good-snapshot"

    private let defaults: UserDefaults
    private let session: WCSession?

    init(
        defaults: UserDefaults = .standard,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.defaults = defaults
        self.session = session
        if let data = defaults.data(forKey: Self.persistedSnapshotKey) {
            snapshot = try? WatchDashboardSnapshot.decode(data)
        }
        super.init()

        guard let session else { return }
        session.delegate = self
        isPhoneReachable = session.isReachable
        session.activate()
        if !session.receivedApplicationContext.isEmpty {
            receive(session.receivedApplicationContext)
        }
    }

    func state(at date: Date = Date()) -> WatchDashboardState {
        WatchDashboardState(
            snapshot: snapshot,
            now: date,
            isPhoneReachable: isPhoneReachable,
            decodingError: decodingError
        )
    }

    func receive(_ applicationContext: [String: Any]) {
        do {
            let decoded = try WatchDashboardSnapshot.decodeApplicationContext(applicationContext)
            let encoded = try decoded.encoded()
            defaults.set(encoded, forKey: Self.persistedSnapshotKey)
            snapshot = decoded
            decodingError = nil
        } catch {
            decodingError = "Couldn’t read the latest iPhone update"
        }
    }

    func updateReachability(_ isReachable: Bool) {
        isPhoneReachable = isReachable
    }
}

extension WatchDashboardStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.updateReachability(session.isReachable)
            if error != nil, self?.snapshot == nil {
                self?.decodingError = "Couldn’t connect to iPhone"
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.receive(applicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.updateReachability(session.isReachable)
        }
    }
}
