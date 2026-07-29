import Combine
import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchDashboardStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchDashboardSnapshot?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var decodingError: String?

    private static let persistedSnapshotKey = "watch.dashboard.last-good-snapshot"

    private let defaults: UserDefaults
    private let complicationStore: WatchComplicationSnapshotStore
    private let reloadComplications: () -> Void
    private let session: WCSession?

    init(
        defaults: UserDefaults = .standard,
        complicationStore: WatchComplicationSnapshotStore = WatchComplicationSnapshotStore(),
        reloadComplications: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationConstants.widgetKind)
        },
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.defaults = defaults
        self.complicationStore = complicationStore
        self.reloadComplications = reloadComplications
        self.session = session
        var migratedSnapshotNeedsReload = false
        if let data = defaults.data(forKey: Self.persistedSnapshotKey),
           let restoredSnapshot = try? WatchDashboardSnapshot.decode(data)
        {
            snapshot = restoredSnapshot
            migratedSnapshotNeedsReload =
                (try? complicationStore.saveIfChanged(restoredSnapshot)) == true
        } else {
            snapshot = complicationStore.load()
        }
        super.init()

        if migratedSnapshotNeedsReload {
            reloadComplications()
        }

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
            let shouldReloadComplications = try complicationStore.saveIfChanged(decoded)
            defaults.set(encoded, forKey: Self.persistedSnapshotKey)
            snapshot = decoded
            decodingError = nil
            if shouldReloadComplications {
                reloadComplications()
            }
        } catch {
            decodingError = "Couldn’t read the latest iPhone update"
        }
    }

    func updateReachability(_ isReachable: Bool) {
        isPhoneReachable = isReachable
    }

    func activationCompleted(
        applicationContext: [String: Any],
        isPhoneReachable: Bool,
        error: Error?
    ) {
        updateReachability(isPhoneReachable)
        if !applicationContext.isEmpty {
            receive(applicationContext)
        } else if error != nil, snapshot == nil {
            decodingError = "Couldn’t connect to iPhone"
        }
    }
}

extension WatchDashboardStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.activationCompleted(
                applicationContext: session.receivedApplicationContext,
                isPhoneReachable: session.isReachable,
                error: error
            )
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
