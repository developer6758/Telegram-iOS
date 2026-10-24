import Foundation

public final class CapsuleCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [() -> Void] = []
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); guard !cancelled else { lock.unlock(); return }
        cancelled = true; let callbacks = actions; actions.removeAll(); lock.unlock()
        for action in callbacks { action() }
    }
    func add(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); action() } else { actions.append(action); lock.unlock() }
    }
}

public struct CapsuleAuthStart {
    public let transactionId: String
    public let authorizationURL: URL
    public let expiresMs: Int64
    public let completionVerifier: String
}

struct CapsuleAuthStartResponse: Decodable {
    let transactionId: String
    let authorizationURL: URL
    let expiresMs: Int64
    enum CodingKeys: String, CodingKey { case transactionId = "transaction_id", authorizationURL = "authorization_url", expiresMs = "expires_ms" }
}
struct CapsuleReserveResponse: Codable {
    let capsuleId: String
    let bindingB64URL: String
    let expiresMs: Int64
    let serverMs: Int64
    enum CodingKeys: String, CodingKey { case capsuleId = "capsule_id", bindingB64URL = "binding_b64url", expiresMs = "expires_ms", serverMs = "server_ms" }
}
struct CapsuleSealResponse: Decodable {
    let carrier: String
    let serverMs: Int64
    enum CodingKeys: String, CodingKey { case carrier, serverMs = "server_ms" }
}
struct CapsuleReleaseResponse: Codable {
    let bindingB64URL: String
    let nonce: String
    let ciphertext: String
    let tag: String
    let contentKey: String
    let serverMs: Int64
    let revision: Int64
    enum CodingKeys: String, CodingKey { case bindingB64URL = "binding_b64url", nonce, ciphertext, tag, contentKey = "content_key", serverMs = "server_ms", revision }
}
struct CapsuleServerError: Decodable {
    let code: String
    let retryable: Bool?
    let serverMs: Int64?
    let unlockMs: Int64?
    enum CodingKeys: String, CodingKey { case code, retryable, serverMs = "server_ms", unlockMs = "unlock_ms" }
}
struct CapsuleMetadataResponse: Decodable {
    let capsules: [CapsuleMetadata]
    let serverMs: Int64
    enum CodingKeys: String, CodingKey { case capsules, serverMs = "server_ms" }
}
struct CapsuleMetadata: Decodable {
    let capsuleId: String
    let carrier: String?
    let state: String
    let revision: Int64
    let hidden: Bool
    enum CodingKeys: String, CodingKey { case capsuleId = "capsule_id", carrier, state, revision, hidden }
}
private final class CapsuleHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class CapsuleAPI {
    private let configuration: CapsuleConfiguration
    private let delegate: CapsuleHTTPDelegate
    private let session: URLSession
    let clock: CapsuleClock
    init(configuration: CapsuleConfiguration, clock: CapsuleClock) {
        self.configuration = configuration
        self.clock = clock
        let delegate = CapsuleHTTPDelegate()
        self.delegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    func request<T: Decodable>(path: String, method: String = "POST", body: Data? = nil, token: String? = nil, idempotencyKey: String? = nil, cancellation: CapsuleCancellation, completion: @escaping (Result<T, Error>) -> Void) {
        guard !cancellation.isCancelled else { completion(.failure(CapsuleError.cancelled)); return }
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey = idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let startedAt = CapsuleClock.continuousMs()
        let task = session.dataTask(with: request) { [clock] data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, let data = data, data.count <= 160_000 else { completion(.failure(CapsuleError.invalidData)); return }
            if let server = try? CapsuleStrictJSON.decode(CapsuleTimeResponse.self, from: data) {
                clock.update(serverMs: server.serverMs, startedAt: startedAt, receivedAt: CapsuleClock.continuousMs())
            }
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 401 { completion(.failure(CapsuleError.notAuthenticated)); return }
                if let failure = try? CapsuleStrictJSON.decode(CapsuleServerError.self, from: data) {
                    completion(.failure(CapsuleError.server(code: String(failure.code.prefix(64)), retryable: failure.retryable ?? false, unlockMs: failure.unlockMs)))
                } else { completion(.failure(CapsuleError.unavailable)) }
                return
            }
            do { completion(.success(try CapsuleStrictJSON.decode(T.self, from: data))) } catch { completion(.failure(error)) }
        }
        cancellation.add { task.cancel() }
        task.resume()
    }
}

struct CapsuleTimeResponse: Decodable {
    let serverMs: Int64
    enum CodingKeys: String, CodingKey { case serverMs = "server_ms" }
}
struct CapsuleEmptyResponse: Decodable {}
