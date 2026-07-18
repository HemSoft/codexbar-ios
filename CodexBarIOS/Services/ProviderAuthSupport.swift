import Foundation
import Network

enum ProviderCredentialRefreshResult<Credentials: Sendable>: Sendable {
    case success(Credentials)
    case expired
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}

enum ProviderCredentialRefreshPreparation<Credentials: Sendable>: Sendable {
    case request(URLRequest)
    case finished(ProviderCredentialRefreshResult<Credentials>)
}

func performProviderCredentialRefresh<Credentials: Equatable & Sendable>(
    credentials: Credentials,
    keychainAccount: String,
    secretStore: SecretStore,
    session: URLSession,
    now: @Sendable () -> Date,
    parse: @Sendable (String) -> Credentials?,
    storedCredential: @Sendable (Credentials) -> String,
    prepare: @Sendable (Date) -> ProviderCredentialRefreshPreparation<Credentials>,
    decode: @Sendable (Data, Date) -> ProviderCredentialRefreshResult<Credentials>
) async -> ProviderCredentialRefreshResult<Credentials> {
    do {
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let latestCredentials = parse(storedSecret)
        else {
            return .rejected
        }
        if latestCredentials != credentials {
            return .success(latestCredentials)
        }
    } catch {
        return .temporarilyUnavailable
    }

    let refreshedAt = now()
    let request: URLRequest
    switch prepare(refreshedAt) {
    case .request(let preparedRequest):
        request = preparedRequest
    case .finished(let result):
        return result
    }

    do {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return .temporarilyUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            return [400, 401, 403].contains(httpResponse.statusCode) ? .rejected : .temporarilyUnavailable
        }

        let decoded = decode(data, refreshedAt)
        guard case .success(let updated) = decoded else {
            return decoded
        }

        do {
            guard
                let storedSecret = try secretStore.readSecret(account: keychainAccount),
                let latestCredentials = parse(storedSecret)
            else {
                return .rejected
            }
            if latestCredentials != credentials {
                return .success(latestCredentials)
            }
            try secretStore.saveSecret(storedCredential(updated), account: keychainAccount)
        } catch {
            return .persistenceFailed
        }
        return .success(updated)
    } catch {
        return .temporarilyUnavailable
    }
}

enum ProviderSecretNormalizer {
    static func normalizedSecret(
        from storedSecret: String?,
        removingPrefixes prefixes: [String] = ["authorization:", "bearer "]
    ) -> String? {
        guard var secret = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            return nil
        }

        if secret.hasPrefix("\""), secret.hasSuffix("\""), secret.count >= 2 {
            secret.removeFirst()
            secret.removeLast()
        }

        for prefix in prefixes where secret.lowercased().hasPrefix(prefix) {
            secret = String(secret.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return secret.isEmpty ? nil : secret
    }
}

enum OAuthFormEncoder {
    private static let allowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func encode(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }
}

enum LoopbackOAuthBindHost {
    case localhost
    case ipv4

    fileprivate var endpointHost: NWEndpoint.Host {
        switch self {
        case .localhost:
            Self.preferredLocalhostLoopbackHost()
        case .ipv4:
            .ipv4(.loopback)
        }
    }

    private static func preferredLocalhostLoopbackHost() -> NWEndpoint.Host {
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", nil, nil, &addresses) == 0, let addresses else {
            return .ipv4(.loopback)
        }
        defer { freeaddrinfo(addresses) }

        var address: UnsafeMutablePointer<addrinfo>? = addresses
        while let candidate = address {
            switch candidate.pointee.ai_family {
            case AF_INET6:
                return .ipv6(.loopback)
            case AF_INET:
                return .ipv4(.loopback)
            default:
                address = candidate.pointee.ai_next
            }
        }
        return .ipv4(.loopback)
    }
}

final class LoopbackOAuthCallbackServer<AuthError: LocalizedError & Sendable>: @unchecked Sendable {
    let port: UInt16

    private let expectedState: String
    private let callbackPath: String
    private let couldNotStartError: AuthError
    private let missingCodeError: AuthError
    private let stateMismatchError: AuthError
    private let timeoutError: AuthError
    private let successHeading: String
    private let failureHeading: String
    private let maximumRequestLength: Int
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?

    private init(
        port: UInt16,
        expectedState: String,
        callbackPath: String,
        bindHost: LoopbackOAuthBindHost,
        queueLabel: String,
        couldNotStartError: AuthError,
        missingCodeError: AuthError,
        stateMismatchError: AuthError,
        timeoutError: AuthError,
        successHeading: String,
        failureHeading: String,
        maximumRequestLength: Int
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw couldNotStartError
        }

        self.port = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.couldNotStartError = couldNotStartError
        self.missingCodeError = missingCodeError
        self.stateMismatchError = stateMismatchError
        self.timeoutError = timeoutError
        self.successHeading = successHeading
        self.failureHeading = failureHeading
        self.maximumRequestLength = maximumRequestLength
        self.queue = DispatchQueue(label: queueLabel)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: bindHost.endpointHost, port: nwPort)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
    }

    static func start(
        preferredPorts: [UInt16],
        expectedState: String,
        callbackPath: String,
        bindHost: LoopbackOAuthBindHost,
        queueLabel: String,
        couldNotStartError: AuthError,
        missingCodeError: AuthError,
        stateMismatchError: AuthError,
        timeoutError: AuthError,
        successHeading: String,
        failureHeading: String,
        maximumRequestLength: Int = 8192
    ) async throws -> LoopbackOAuthCallbackServer<AuthError> {
        var lastError: Error = couldNotStartError
        for port in preferredPorts {
            do {
                let server = try LoopbackOAuthCallbackServer(
                    port: port,
                    expectedState: expectedState,
                    callbackPath: callbackPath,
                    bindHost: bindHost,
                    queueLabel: queueLabel,
                    couldNotStartError: couldNotStartError,
                    missingCodeError: missingCodeError,
                    stateMismatchError: stateMismatchError,
                    timeoutError: timeoutError,
                    successHeading: successHeading,
                    failureHeading: failureHeading,
                    maximumRequestLength: maximumRequestLength
                )
                try await server.startListening()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func waitForCallback(timeoutNanoseconds: UInt64) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            finishCallback(.failure(timeoutError))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingCallbackResult {
                self.pendingCallbackResult = nil
                lock.unlock()
                continuation.resume(with: pendingCallbackResult)
                return
            }
            callbackContinuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        listener.cancel()
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            finishReady(.success(()))
        case .failed(let error):
            finishReady(.failure(error))
            finishCallback(.failure(error))
        case .cancelled:
            finishReady(.failure(couldNotStartError))
            finishCallback(.failure(missingCodeError))
        default:
            break
        }
    }

    private func finishReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingCallbackResult = result
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumRequestLength) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = parseCallbackURL(from: request)
            let response = httpResponse(for: result)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            finishCallback(result)
        }
    }

    private func parseCallbackURL(from request: String) -> Result<URL, Error> {
        guard
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET "),
            let pathStart = requestLine.firstIndex(of: " "),
            let pathEnd = requestLine[requestLine.index(after: pathStart)...].firstIndex(of: " ")
        else {
            return .failure(missingCodeError)
        }

        let path = String(requestLine[requestLine.index(after: pathStart)..<pathEnd])
        guard path.hasPrefix(callbackPath) else {
            return .failure(missingCodeError)
        }
        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            return .failure(missingCodeError)
        }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
        else {
            return .failure(stateMismatchError)
        }
        guard components.queryItems?.first(where: { $0.name == "code" })?.value?.isEmpty == false else {
            return .failure(missingCodeError)
        }
        return .success(url)
    }

    private func httpResponse(for result: Result<URL, Error>) -> String {
        let statusLine: String
        let heading: String
        let message: String
        switch result {
        case .success:
            statusLine = "HTTP/1.1 200 OK"
            heading = successHeading
            message = "You can return to CodexBar."
        case .failure(let error):
            statusLine = "HTTP/1.1 400 Bad Request"
            heading = failureHeading
            message = error.localizedDescription
        }

        let body = """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body><h1>\(heading)</h1><p>\(message)</p></body></html>
        """
        return """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}
