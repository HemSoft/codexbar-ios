#if canImport(UIKit)
import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeBrowserCompletionTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testClosingBrowserAfterApprovalDoesNotDiscardInFlightCompletion() async {
        let browser = CompletionTestBrowser()
        let completing = expectation(description: "Provider approval is completing")
        let connected = expectation(description: "The first attempt completes")
        let gate = CompletionTestGate()
        let client = OpenCodeBrowserClient(
            begin: { Self.authorization },
            authorize: { _, _ in
                completing.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: {}
        )
        let session = OpenCodeBrowserSignInSession(presenter: browser, makeClient: { client }, completion: { result in
            guard case .success(let value) = result else { return XCTFail("Approved attempt failed") }
            XCTAssertEqual(value.workspaceID, "wrk_one")
            connected.fulfill()
        })
        session.start(mode: .existingSession)
        await fulfillment(of: [completing], timeout: 1)
        // Website approval and client completion are distinct events. The user
        // closes the browser while the approved result is still in flight.
        browser.close()
        await gate.release()
        await fulfillment(of: [connected], timeout: 1)
        session.invalidate()
    }

    @MainActor
    func testTokenReceiptReturnsToAppBeforeIdentityCompletes() async {
        let browser = CompletionTestBrowser()
        let verifying = expectation(description: "Token received, identity pending")
        let connected = expectation(description: "Identity completes")
        let gate = CompletionTestGate()
        var completed = false
        let client = OpenCodeBrowserClient(
            begin: { Self.authorization },
            authorize: { _, callbacks in
                await callbacks.tokenReceived()
                verifying.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: {}
        )
        let session = OpenCodeBrowserSignInSession(presenter: browser, makeClient: { client }, completion: { _ in
            completed = true
            connected.fulfill()
        })
        session.start(mode: .privateSession)
        await fulfillment(of: [verifying], timeout: 2)
        XCTAssertNil(browser.onClose, "The browser must close before identity verification finishes")
        XCTAssertEqual(session.progress, .verifyingAccount)
        XCTAssertFalse(completed, "Token receipt alone is not a verified credential")
        await gate.release()
        await fulfillment(of: [connected], timeout: 2)
    }

    @MainActor
    func testExplicitAppCancellationDiscardsLateApprovedResult() async {
        let browser = CompletionTestBrowser()
        let completing = expectation(description: "Approval in flight")
        let finished = expectation(description: "Client cleaned up")
        let gate = CompletionTestGate()
        var completions = 0
        let client = OpenCodeBrowserClient(
            begin: { Self.authorization },
            authorize: { _, _ in
                completing.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: { finished.fulfill() }
        )
        let session = OpenCodeBrowserSignInSession(presenter: browser, makeClient: { client }, completion: { result in
            completions += 1
            guard case .failure(OpenCodeSignInError.canceled) = result else { return XCTFail("Expected cancellation") }
        })
        session.start(mode: .existingSession)
        await fulfillment(of: [completing], timeout: 2)
        session.cancel()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(session.browserMode)
    }

    @MainActor
    func testBrowserCloseWaitsThroughTheAdvertisedPollingInterval() async {
        let browser = CompletionTestBrowser()
        let polling = expectation(description: "Waiting for the provider interval")
        let prematureEnd = expectation(description: "Must not end before the permitted poll")
        prematureEnd.isInverted = true
        let finished = expectation(description: "Client cleaned up")
        let gate = CompletionTestGate()
        var completed = false
        let client = OpenCodeBrowserClient(
            begin: {
                OpenCodeDeviceAuthorization(
                    deviceCode: "slow-device", verificationURL: Self.authorization.verificationURL,
                    expiresAt: .distantFuture, interval: 60
                )
            },
            authorize: { _, _ in
                polling.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: { finished.fulfill() }
        )
        let session = OpenCodeBrowserSignInSession(
            presenter: browser, makeClient: { client }, approvalCheckTimeout: .milliseconds(20),
            completion: { _ in completed = true }
        )
        session.start(mode: .existingSession)
        await fulfillment(of: [polling], timeout: 2)
        let observation = session.$browserMode.dropFirst().sink { if $0 == nil { prematureEnd.fulfill() } }
        browser.close()
        await fulfillment(of: [prematureEnd], timeout: 0.06)
        observation.cancel()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(completed)
    }

    @MainActor
    func testSlowDownReschedulesAnAlreadyOpenApprovalCheck() async {
        let browser = CompletionTestBrowser()
        let polling = expectation(description: "Old poll is in flight")
        let prematureEnd = expectation(description: "Slow-down interval must be honored")
        prematureEnd.isInverted = true
        let finished = expectation(description: "Client cleaned up")
        let gate = CompletionTestGate()
        let callbacks = CompletionTestCallbacks()
        var completed = false
        let client = OpenCodeBrowserClient(
            begin: { Self.authorization },
            authorize: { _, value in
                await callbacks.store(value)
                await value.pollScheduled(0)
                polling.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: { finished.fulfill() }
        )
        let session = OpenCodeBrowserSignInSession(
            presenter: browser, makeClient: { client }, approvalCheckTimeout: .milliseconds(20),
            completion: { _ in completed = true }
        )
        session.start(mode: .existingSession)
        await fulfillment(of: [polling], timeout: 2)
        let observation = session.$browserMode.dropFirst().sink { if $0 == nil { prematureEnd.fulfill() } }
        browser.close()
        await callbacks.schedulePoll(after: 65)
        await fulfillment(of: [prematureEnd], timeout: 0.06)
        observation.cancel()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(completed)
    }

    @MainActor
    func testBrowserCloseCheckTimesOutAndIgnoresLateSuccess() async {
        let browser = CompletionTestBrowser()
        let completing = expectation(description: "Approval in flight")
        let choices = expectation(description: "Bounded check returns to choices")
        let finished = expectation(description: "Client cleaned up")
        let gate = CompletionTestGate()
        var completions = 0
        let client = OpenCodeBrowserClient(
            begin: { Self.authorization },
            authorize: { _, callbacks in
                await callbacks.pollScheduled(0)
                completing.fulfill()
                await gate.wait()
                return Self.credential
            },
            invalidate: { finished.fulfill() }
        )
        let session = OpenCodeBrowserSignInSession(
            presenter: browser, makeClient: { client }, approvalCheckTimeout: .milliseconds(20),
            completion: { _ in completions += 1 }
        )
        session.start(mode: .existingSession)
        await fulfillment(of: [completing], timeout: 2)
        let observation = session.$browserMode.dropFirst().sink { if $0 == nil { choices.fulfill() } }
        browser.close()
        XCTAssertEqual(session.progress, .checkingApproval)
        await fulfillment(of: [choices], timeout: 2)
        XCTAssertNotNil(session.retryMessage)
        observation.cancel()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(completions, 0)
        session.invalidate()
    }

    @MainActor
    func testUnapprovedCloseAllowsFreshAttemptAndIgnoresOldBrowserCallback() async {
        let browser = CompletionTestBrowser()
        let polling = expectation(description: "First challenge polling")
        let firstFinished = expectation(description: "Unapproved check ends")
        let secondPolling = expectation(description: "Fresh challenge polling")
        let connected = expectation(description: "Fresh challenge completes")
        let firstGate = CompletionTestGate()
        let secondGate = CompletionTestGate()
        let clients = CompletionTestClients([
            OpenCodeBrowserClient(
                begin: { Self.authorization },
                authorize: { _, callbacks in
                    polling.fulfill()
                    await firstGate.wait()
                    let keepPolling = await callbacks.shouldContinuePolling()
                    XCTAssertFalse(keepPolling)
                    throw OpenCodeSignInError.approvalNotReady
                },
                invalidate: { firstFinished.fulfill() }
            ),
            OpenCodeBrowserClient(
                begin: {
                    OpenCodeDeviceAuthorization(
                        deviceCode: "fresh-device", verificationURL: Self.authorization.verificationURL,
                        expiresAt: .distantFuture, interval: 5
                    )
                },
                authorize: { authorization, _ in
                    XCTAssertEqual(authorization.deviceCode, "fresh-device")
                    secondPolling.fulfill()
                    await secondGate.wait()
                    return Self.credential
                },
                invalidate: {}
            ),
        ])
        let session = OpenCodeBrowserSignInSession(presenter: browser, makeClient: { clients.next() }, completion: { result in
            guard case .success = result else { return XCTFail("Fresh approval failed") }
            connected.fulfill()
        })
        session.start(mode: .existingSession)
        await fulfillment(of: [polling], timeout: 2)
        let staleBrowserCallback = browser.onClose
        browser.close()
        await firstGate.release()
        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertNil(session.browserMode)
        XCTAssertNotNil(session.retryMessage)
        session.start(mode: .privateSession)
        await fulfillment(of: [secondPolling], timeout: 2)
        staleBrowserCallback?()
        XCTAssertEqual(session.browserMode, .privateSession)
        XCTAssertEqual(session.progress, .waitingForApproval)
        XCTAssertNil(session.retryMessage)
        await secondGate.release()
        await fulfillment(of: [connected], timeout: 2)
    }

    private static let authorization = OpenCodeDeviceAuthorization(
        deviceCode: "synthetic-device", verificationURL: URL(string: "https://opencode.ai/console/device")!,
        expiresAt: .distantFuture, interval: 5
    )
    private static let credential = OpenCodeConsoleCredential(
        kind: "opencode-console-v1", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        expiresAt: .distantFuture, workspaceID: "wrk_one", userID: "user_one"
    )
}

@MainActor
private final class CompletionTestBrowser: OpenCodeBrowserPresenting {
    var onClose: (() -> Void)?
    func present(url: URL, prefersEphemeralSession: Bool, onCancel: @escaping () -> Void) -> Bool {
        onClose = onCancel
        return true
    }
    func finish() { onClose = nil }
    func close() { onClose?() }
}

private final class CompletionTestClients: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [OpenCodeBrowserClient]
    init(_ clients: [OpenCodeBrowserClient]) { self.clients = clients }
    func next() -> OpenCodeBrowserClient { lock.withLock { clients.removeFirst() } }
}

private actor CompletionTestCallbacks {
    private var value: OpenCodeBrowserCallbacks?
    func store(_ value: OpenCodeBrowserCallbacks) { self.value = value }
    func schedulePoll(after delay: TimeInterval) async { await value?.pollScheduled(delay) }
}

private actor CompletionTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
