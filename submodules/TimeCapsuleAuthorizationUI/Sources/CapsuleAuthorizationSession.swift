import AuthenticationServices
import Foundation
import TimeCapsuleCore
import UIKit

/// Foreground-only service login. The browser callback carries no bearer token: the initiating
/// app proves possession of its completion verifier over HTTPS while this sheet is active.
public final class CapsuleAuthorizationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service: CapsuleService
    private weak var anchor: UIWindow?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var browser: ASWebAuthenticationSession?
    private var request: CapsuleCancellation?
    private var transaction: CapsuleAuthStart?
    private var generation = 0
    private var retryDelay: Double = 0.8
    private var startTime: TimeInterval = 0.0
    private var backgroundObserver: NSObjectProtocol?

    public init(service: CapsuleService, anchor: UIWindow, completion: @escaping (Result<Void, Error>) -> Void) {
        self.service = service
        self.anchor = anchor
        self.completion = completion
        super.init()
    }

    deinit {
        self.request?.cancel()
        self.browser?.cancel()
        if let backgroundObserver = self.backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.anchor ?? ASPresentationAnchor()
    }

    public func start() {
        guard self.completion != nil, self.transaction == nil else { return }
        self.startTime = ProcessInfo.processInfo.systemUptime
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancel()
        }
        self.request = self.service.authStart { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.completion != nil else { return }
                self.request = nil
                switch result {
                case let .failure(error):
                    self.finish(.failure(error))
                case let .success(transaction):
                    self.transaction = transaction
                    let browser = ASWebAuthenticationSession(url: transaction.authorizationURL, callbackURLScheme: nil) { [weak self] _, error in
                        DispatchQueue.main.async {
                            guard let self, self.completion != nil else { return }
                            let error = error as NSError?
                            if error?.domain == ASWebAuthenticationSessionError.errorDomain && error?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                                self.finish(.failure(CapsuleAuthorizationError.cancelled))
                            } else if let error {
                                self.finish(.failure(error))
                            } else {
                                // A successful browser callback does not contain our bearer session.
                                // Keep proving completion to the configured service instead of treating
                                // an HTTPS callback as a cancelled login.
                                self.browser = nil
                                self.poll()
                            }
                        }
                    }
                    browser.presentationContextProvider = self
                    browser.prefersEphemeralWebBrowserSession = true
                    self.browser = browser
                    guard browser.start() else {
                        self.finish(.failure(CapsuleAuthorizationError.unavailable))
                        return
                    }
                    self.poll()
                }
            }
        }
    }

    public func cancel() {
        self.finish(.failure(CapsuleAuthorizationError.cancelled))
    }

    private func poll() {
        guard let transaction = self.transaction, self.completion != nil, self.request == nil else { return }
        // A bounded monotonic lifetime is independent of a device wall-clock change.
        guard ProcessInfo.processInfo.systemUptime - self.startTime < 600.0 else {
            self.finish(.failure(CapsuleAuthorizationError.expired))
            return
        }
        let generation = self.generation
        self.request = self.service.authComplete(transaction: transaction) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.completion != nil, self.generation == generation else { return }
                self.request = nil
                switch result {
                case .success(true):
                    self.finish(.success(()))
                case .success(false):
                    let delay = self.retryDelay
                    self.retryDelay = min(3.0, self.retryDelay * 1.25)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.generation == generation, self.completion != nil else { return }
                        self.poll()
                    }
                case let .failure(error):
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion = self.completion else { return }
        self.completion = nil
        self.generation += 1
        self.request?.cancel()
        self.request = nil
        self.browser?.cancel()
        self.browser = nil
        self.transaction = nil
        if let backgroundObserver = self.backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        completion(result)
    }
}

public enum CapsuleAuthorizationError: LocalizedError {
    case cancelled
    case unavailable
    case expired

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign in was cancelled."
        case .unavailable: return "The sign in browser is unavailable."
        case .expired: return "Sign in expired. Please try again."
        }
    }
}
