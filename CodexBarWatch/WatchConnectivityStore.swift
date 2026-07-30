import Combine
import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchDashboardStore: NSObject, ObservableObject {
    typealias SnapshotRequester = (@escaping (Error) -> Void) -> Void

    @Published private(set) var snapshot: WatchDashboardSnapshot?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var decodingError: String?

    private static let persistedSnapshotKey = "watch.dashboard.last-good-snapshot"

    private let defaults: UserDefaults
    private let complicationStore: WatchComplicationSnapshotStore
    private let reloadComplications: () -> Void
    private let session: WCSession?
    private let requestSnapshot: SnapshotRequester?

    init(
        defaults: UserDefaults = .standard,
        complicationStore: WatchComplicationSnapshotStore = WatchComplicationSnapshotStore(),
        reloadComplications: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationConstants.widgetKind)
        },
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        requestSnapshot: SnapshotRequester? = nil
    ) {
        self.defaults = defaults
        self.complicationStore = complicationStore
        self.reloadComplications = reloadComplications
        self.session = session
        if let requestSnapshot {
            self.requestSnapshot = requestSnapshot
        } else if let session {
            self.requestSnapshot = { errorHandler in
                session.sendMessage(
                    WatchDashboardSnapshot.snapshotRequestMessage,
                    replyHandler: nil,
                    errorHandler: errorHandler
                )
            }
        } else {
            self.requestSnapshot = nil
        }
        var migratedSnapshotNeedsReload = false
        let legacyData = defaults.data(forKey: Self.persistedSnapshotKey)
        let legacySnapshot = legacyData.flatMap { try? WatchDashboardSnapshot.decode($0) }
        let sharedSnapshot = complicationStore.load()
        if let legacySnapshot,
           sharedSnapshot == nil
                || legacySnapshot.generatedAt
                    > (sharedSnapshot?.generatedAt ?? .distantPast)
        {
            snapshot = legacySnapshot
            migratedSnapshotNeedsReload = (
                try? complicationStore.saveIfChanged(
                    legacySnapshot,
                    encodedData: legacyData
                )
            ) == true
        } else if let sharedSnapshot {
            snapshot = sharedSnapshot
            if legacySnapshot != sharedSnapshot,
               let sharedData = try? sharedSnapshot.encoded()
            {
                defaults.set(sharedData, forKey: Self.persistedSnapshotKey)
            }
        } else {
            snapshot = nil
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
            let shouldReloadComplications = try complicationStore.saveIfChanged(
                decoded,
                encodedData: encoded
            )
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
        let becameReachable = !isPhoneReachable && isReachable
        isPhoneReachable = isReachable
        if becameReachable {
            requestCurrentSnapshot()
        }
    }

    func activationCompleted(
        applicationContext: [String: Any],
        isPhoneReachable: Bool,
        error: Error?
    ) {
        self.isPhoneReachable = isPhoneReachable
        if !applicationContext.isEmpty {
            receive(applicationContext)
        } else if error != nil, snapshot == nil {
            decodingError = "Couldn’t connect to iPhone"
        }
        if error == nil {
            requestCurrentSnapshot()
        }
    }

    func requestCurrentSnapshot() {
        requestSnapshot? { [weak self] _ in
            Task { @MainActor in
                guard let self, self.snapshot == nil else { return }
                self.decodingError = "Couldn’t request the latest update from iPhone"
            }
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
