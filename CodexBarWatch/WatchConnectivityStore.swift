import Combine
import Foundation
import OSLog
import WatchConnectivity
import WidgetKit

enum WatchConnectivityDelegateEvent: Sendable {
    case activation(
        sequence: UInt64,
        activationState: WCSessionActivationState,
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
        case let .activation(sequence, _, _, _, _),
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

enum WatchSnapshotRequestFailure: Equatable, Sendable {
    case sessionInactive
    case phoneUnreachable
    case timedOut
    case pairingUnavailable
    case deliveryFailed

    init(_ error: Error) {
        let nsError = error as NSError
        guard nsError.domain == WCErrorDomain,
              let code = WCError.Code(rawValue: nsError.code)
        else {
            self = .deliveryFailed
            return
        }
        switch code {
        case .sessionNotActivated:
            self = .sessionInactive
        case .notReachable:
            self = .phoneUnreachable
        case .messageReplyTimedOut, .transferTimedOut:
            self = .timedOut
        case .deviceNotPaired, .companionAppNotInstalled, .watchAppNotInstalled:
            self = .pairingUnavailable
        default:
            self = .deliveryFailed
        }
    }

    var recoveryMessage: String {
        switch self {
        case .sessionInactive:
            "Connecting to iPhone. Keep CodexBar open on both devices"
        case .phoneUnreachable:
            "iPhone unavailable. Open CodexBar there; update queued"
        case .timedOut:
            "iPhone did not respond. Open CodexBar there; update queued"
        case .pairingUnavailable:
            "Install and open CodexBar on the paired iPhone"
        case .deliveryFailed:
            "Update queued. Open CodexBar on iPhone to finish"
        }
    }
}

@MainActor
final class WatchDashboardStore: NSObject, ObservableObject {
    typealias SnapshotRequester = (
        @escaping @MainActor (WatchDashboardSnapshotResponse) -> Void,
        @escaping @MainActor (WatchSnapshotRequestFailure) -> Void
    ) -> Void
    typealias SnapshotRequestQueuer = () -> Void

    private static let logger = Logger(
        subsystem: "com.hemsoft.CodexBarIOS",
        category: "WatchConnectivity.Watch"
    )
    @Published private(set) var snapshot: WatchDashboardSnapshot?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var decodingError: String?

    private static let persistedSnapshotKey = "watch.dashboard.last-good-snapshot"

    private let defaults: UserDefaults
    private let complicationStore: WatchComplicationSnapshotStore
    private let reloadComplications: () -> Void
    private let session: WCSession?
    private let requestSnapshot: SnapshotRequester?
    private let queueSnapshotRequest: SnapshotRequestQueuer?
    private let requestCoalescingDelay: Duration
    private var activationState: WCSessionActivationState
    nonisolated private let delegateEventSequencer = WatchConnectivityEventSequencer()
    private var nextDelegateEventSequence: UInt64 = 0
    private var pendingDelegateEvents: [UInt64: WatchConnectivityDelegateEvent] = [:]
    private var snapshotRequestTask: Task<Void, Never>?
    private var hasQueuedSnapshotRequest = false

    init(
        defaults: UserDefaults = .standard,
        complicationStore: WatchComplicationSnapshotStore = WatchComplicationSnapshotStore(),
        reloadComplications: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationConstants.widgetKind)
        },
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        requestSnapshot: SnapshotRequester? = nil,
        queueSnapshotRequest: SnapshotRequestQueuer? = nil,
        initialActivationState: WCSessionActivationState? = nil,
        requestCoalescingDelay: Duration = .milliseconds(100)
    ) {
        self.defaults = defaults
        self.complicationStore = complicationStore
        self.reloadComplications = reloadComplications
        self.session = session
        self.requestCoalescingDelay = requestCoalescingDelay
        hasQueuedSnapshotRequest = session?.outstandingUserInfoTransfers.contains {
            WatchDashboardSnapshot.isSnapshotRequest($0.userInfo)
        } ?? false
        activationState = initialActivationState
            ?? session?.activationState
            ?? (requestSnapshot == nil ? .notActivated : .activated)
        if let requestSnapshot {
            self.requestSnapshot = requestSnapshot
        } else if let session {
            self.requestSnapshot = { replyHandler, errorHandler in
                session.sendMessage(
                    WatchDashboardSnapshot.snapshotRequestMessage,
                    replyHandler: { reply in
                        let response = WatchDashboardSnapshotResponse(reply)
                        Task { @MainActor in
                            replyHandler(response)
                        }
                    },
                    errorHandler: { error in
                        let failure = WatchSnapshotRequestFailure(error)
                        Task { @MainActor in
                            errorHandler(failure)
                        }
                    }
                )
            }
        } else {
            self.requestSnapshot = nil
        }
        if let queueSnapshotRequest {
            self.queueSnapshotRequest = queueSnapshotRequest
        } else if let session {
            self.queueSnapshotRequest = {
                session.transferUserInfo(WatchDashboardSnapshot.snapshotRequestMessage)
            }
        } else {
            self.queueSnapshotRequest = nil
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
        Self.logger.info(
            "Starting Watch session state=\(session.activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public)"
        )
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
            hasQueuedSnapshotRequest = false
            if shouldReloadComplications {
                reloadComplications()
            }
        } catch {
            decodingError = "Couldn’t read the latest iPhone update"
            Self.logger.error(
                "Snapshot context decode failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)"
            )
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
        activationState: WCSessionActivationState,
        applicationContext: WatchDashboardApplicationContext,
        isPhoneReachable: Bool,
        hadError: Bool
    ) {
        self.activationState = activationState
        self.isPhoneReachable = isPhoneReachable
        Self.logger.info(
            "Activation completed state=\(activationState.rawValue, privacy: .public) reachable=\(isPhoneReachable, privacy: .public) hadError=\(hadError, privacy: .public)"
        )
        if !applicationContext.isEmpty {
            receive(applicationContext)
        } else if (hadError || activationState != .activated), snapshot == nil {
            decodingError = WatchSnapshotRequestFailure.sessionInactive.recoveryMessage
        }
        if !hadError, activationState == .activated {
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
            case let .activation(
                _,
                activationState,
                applicationContext,
                isPhoneReachable,
                hadError
            ):
                activationCompleted(
                    activationState: activationState,
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
        guard activationState == .activated else {
            decodingError = WatchSnapshotRequestFailure.sessionInactive.recoveryMessage
            Self.logger.notice("Snapshot request deferred because session is not activated")
            session?.activate()
            return
        }
        guard isPhoneReachable else {
            queueSnapshotRequest(failure: .phoneUnreachable)
            return
        }
        guard let requestSnapshot else {
            queueSnapshotRequest(failure: .deliveryFailed)
            return
        }
        Self.logger.info("Requesting immediate snapshot from reachable iPhone")
        requestSnapshot(
            { [weak self] response in
                self?.receiveSnapshotResponse(response)
            },
            { [weak self] failure in
                self?.queueSnapshotRequest(failure: failure)
            }
        )
    }

    private func receiveSnapshotResponse(_ response: WatchDashboardSnapshotResponse) {
        switch response {
        case let .snapshot(data):
            receive(.snapshot(data))
            Self.logger.info("Received immediate snapshot reply from iPhone")
        case .unavailable:
            decodingError = "No dashboard update is available yet. Refresh CodexBar on iPhone"
            Self.logger.notice("iPhone replied without an available dashboard snapshot")
        case .malformed:
            decodingError = "Couldn’t read the iPhone update. Refresh CodexBar on iPhone"
            Self.logger.error("iPhone returned a malformed snapshot reply")
        }
    }

    private func queueSnapshotRequest(failure: WatchSnapshotRequestFailure) {
        if failure != .pairingUnavailable,
           !hasQueuedSnapshotRequest,
           let queueSnapshotRequest
        {
            queueSnapshotRequest()
            hasQueuedSnapshotRequest = true
        }
        decodingError = failure.recoveryMessage
        Self.logger.notice(
            "Snapshot request recovery reason=\(String(describing: failure), privacy: .public) queued=\(self.hasQueuedSnapshotRequest, privacy: .public)"
        )
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
                activationState: activationState,
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
