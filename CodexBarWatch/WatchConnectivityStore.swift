import Combine
import Foundation
import WatchConnectivity
import WidgetKit

enum WatchConnectivityDelegateEvent: Sendable {
    case activation(
        sequence: UInt64,
        applicationContext: WatchDashboardApplicationContext,
        isPhoneReachable: Bool,
        hadError: Bool
    )
    case applicationContext(
        sequence: UInt64,
        applicationContext: WatchDashboardApplicationContext
    )
    case reachability(sequence: UInt64, isPhoneReachable: Bool)

    var sequence: UInt64 {
        switch self {
        case let .activation(sequence, _, _, _),
             let .applicationContext(sequence, _),
             let .reachability(sequence, _):
            sequence
        }
    }
}

// `nextSequence` is accessed only under `lock`. `nextEvent` also invokes its
// nonescaping factory while holding that lock, making extraction and sequence
// assignment atomic without allowing a non-Sendable callback value to escape.
private final class WatchConnectivityEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0

    func nextEvent(
        _ makeEvent: (UInt64) -> WatchConnectivityDelegateEvent
    ) -> WatchConnectivityDelegateEvent {
        lock.lock()
        defer { lock.unlock() }
        defer { nextSequence &+= 1 }
        return makeEvent(nextSequence)
    }
}

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
    private let requestCoalescingDelay: Duration
    nonisolated private let delegateEventSequencer = WatchConnectivityEventSequencer()
    private var nextDelegateEventSequence: UInt64 = 0
    private var pendingDelegateEvents: [UInt64: WatchConnectivityDelegateEvent] = [:]
    private var snapshotRequestTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        complicationStore: WatchComplicationSnapshotStore = WatchComplicationSnapshotStore(),
        reloadComplications: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationConstants.widgetKind)
        },
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        requestSnapshot: SnapshotRequester? = nil,
        requestCoalescingDelay: Duration = .milliseconds(100)
    ) {
        self.defaults = defaults
        self.complicationStore = complicationStore
        self.reloadComplications = reloadComplications
        self.session = session
        self.requestCoalescingDelay = requestCoalescingDelay
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
        receive(WatchDashboardApplicationContext(applicationContext))
    }

    func receive(_ applicationContext: WatchDashboardApplicationContext) {
        do {
            let decoded = try applicationContext.decode()
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
            scheduleCurrentSnapshotRequest()
        }
    }

    func activationCompleted(
        applicationContext: WatchDashboardApplicationContext,
        isPhoneReachable: Bool,
        hadError: Bool
    ) {
        self.isPhoneReachable = isPhoneReachable
        if !applicationContext.isEmpty {
            receive(applicationContext)
        } else if hadError, snapshot == nil {
            decodingError = "Couldn’t connect to iPhone"
        }
        if !hadError {
            scheduleCurrentSnapshotRequest()
        }
    }

    func receiveDelegateEvent(_ event: WatchConnectivityDelegateEvent) {
        guard event.sequence >= nextDelegateEventSequence else { return }
        pendingDelegateEvents[event.sequence] = event
        while let nextEvent = pendingDelegateEvents.removeValue(
            forKey: nextDelegateEventSequence
        ) {
            nextDelegateEventSequence &+= 1
            switch nextEvent {
            case let .activation(_, applicationContext, isPhoneReachable, hadError):
                activationCompleted(
                    applicationContext: applicationContext,
                    isPhoneReachable: isPhoneReachable,
                    hadError: hadError
                )
            case let .applicationContext(_, applicationContext):
                receive(applicationContext)
            case let .reachability(_, isPhoneReachable):
                updateReachability(isPhoneReachable)
            }
        }
    }

    func scheduleCurrentSnapshotRequest() {
        snapshotRequestTask?.cancel()
        let delay = requestCoalescingDelay
        snapshotRequestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.requestCurrentSnapshot()
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

    deinit {
        snapshotRequestTask?.cancel()
    }
}

extension WatchDashboardStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.activation(
                sequence: sequence,
                applicationContext: WatchDashboardApplicationContext(
                    session.receivedApplicationContext
                ),
                isPhoneReachable: session.isReachable,
                hadError: error != nil
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.applicationContext(
                sequence: sequence,
                applicationContext: WatchDashboardApplicationContext(applicationContext)
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.reachability(
                sequence: sequence,
                isPhoneReachable: session.isReachable
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }
}
