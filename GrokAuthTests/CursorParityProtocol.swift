import Foundation

// An explicit replay of a cache-aware loading boundary, not proof of live HTTP cache behavior.
final class CursorParityProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var pending: DispatchWorkItem?
    private var stopped = false

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        lock.withLock {
            stopped = true
            pending?.cancel()
            pending = nil
        }
    }

    override func startLoading() {
        guard let url = request.url, url.host == "cursor-parity.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.lastPathComponent == "GetCurrentPeriodUsage" {
            let reloads = request.cachePolicy == .reloadIgnoringLocalCacheData
            complete(status: 200, body: reloads
                     ? #"{"planUsage":{"autoPercentUsed":1,"apiPercentUsed":3}}"#
                     : #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#)
            return
        }
        guard url.lastPathComponent == "GetSandUsageStatus" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mode = url.pathComponents.dropLast().last
        if mode == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = switch mode {
        case "rejected": 401
        case "forbidden": 403
        case "limited": 429
        case "error": 503
        default: 200
        }
        let body = #"{"hasNonZeroIncludedLimit":true,"usagePercent":41}"#
        if mode == "delayed" {
            let work = DispatchWorkItem { [weak self] in self?.complete(status: status, body: body) }
            lock.withLock { pending = work }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: work)
        } else {
            complete(status: status, body: body)
        }
    }

    private func complete(status: Int, body: String) {
        lock.withLock {
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
