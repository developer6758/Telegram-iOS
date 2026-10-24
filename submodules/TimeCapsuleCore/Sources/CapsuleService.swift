import Foundation

/// One service instance owns exactly one numeric Telegram account and one configured origin.
/// The registry is only a lifetime/factory map; credentials and storage never cross instances.
public final class CapsuleService {
    private static let registryLock = NSLock()
    private static var registry: [String: CapsuleService] = [:]
    public static func configured(accountId: String) -> CapsuleService? {
        guard CapsuleWire.validUserId(accountId), let configuration = CapsuleConfiguration.load() else { return nil }
        let identity = configuration.service + ":" + accountId
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[identity] { return existing }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TimeCapsule", isDirectory: true)
                .appendingPathComponent(CapsuleCrypto.digest(Data(identity.utf8)), isDirectory: true)
            let service = try CapsuleService(accountId: accountId, configuration: configuration, directory: directory)
            registry[identity] = service
            return service
        } catch { return nil }
    }

    public let accountId: String
    public let configuration: CapsuleConfiguration
    public let clock = CapsuleClock()
    private let api: CapsuleAPI
    private let store: CapsuleStore
    private let queue = DispatchQueue(label: "org.telegram.TimeCapsule.account", qos: .userInitiated)
    private let stateLock = NSRecursiveLock()
    private var active: [UUID: CapsuleCancellation] = [:]
    private var verified: [String: CapsuleEnvelope] = [:]
    private var generation: UInt64 = 0
    private var invalidated = false
    private var timeWaiters: [(CapsuleCancellation, (Result<Void, Error>) -> Void)] = []
    private var timeRequest: CapsuleCancellation?
    private var lastTimeRequest: Double = 0
    private var openWaiters: [String: [(CapsuleCancellation, (Result<CapsulePayload, Error>) -> Void)]] = [:]
    private var deletedIds = Set<String>()
    private var releasedMemory: [String: CapsuleCachedRelease] = [:]
    private var descriptorDigests: [String: String] = [:]
    private var refreshWaiters: [(CapsuleCancellation, (Result<CapsuleSession, Error>) -> Void)] = []
    private var refreshRequest: CapsuleCancellation?
    private var sealWaiters: [String: [(CapsuleCancellation, (Result<CapsuleSealedMessage, Error>) -> Void)]] = [:]
    private var sealRequests: [String: CapsuleCancellation] = [:]

    public init(accountId: String, configuration: CapsuleConfiguration, directory: URL) throws {
        guard CapsuleWire.validUserId(accountId) else { throw CapsuleError.invalidData }
        try configuration.validate()
        self.accountId = accountId; self.configuration = configuration
        self.store = try CapsuleStore(accountId: accountId, service: configuration.service, directory: directory)
        self.api = CapsuleAPI(configuration: configuration, clock: clock)
        let initialState = try store.read()
        deletedIds = Set(initialState.deletions.keys).union(initialState.unavailableRevisions?.keys.map { $0 } ?? [])
        releasedMemory = initialState.releases
    }

    public var hasSession: Bool { return (try? store.read().session?.telegramId) == accountId }
    public func verify(carrier: String, context: CapsuleMessageContext) throws -> CapsuleEnvelope {
        guard context.accountId == accountId else { throw CapsuleError.accountMismatch }
        stateLock.lock(); let existing = verified[carrier]; stateLock.unlock()
        if let existing = existing { try context.validate(existing.descriptor); return existing }
        let envelope = try CapsuleEnvelopeCodec.verify(carrier, configuration: configuration, context: context)
        stateLock.lock()
        if verified.count >= 512 { verified.removeAll(keepingCapacity: true) }
        verified[carrier] = envelope
        descriptorDigests[envelope.descriptor.capsuleId] = CapsuleCrypto.digest(envelope.descriptorBytes)
        stateLock.unlock()
        return envelope
    }
    public func remainingSeconds(descriptor: CapsuleDescriptor) -> Int64 {
        return min(descriptor.durationSeconds, CapsuleCountdown.remainingSeconds(unlockMs: descriptor.unlockMs, estimatedServerMs: clock.estimatedServerMs))
    }
    public func cachedPayload(capsuleId: String) -> CapsulePayload? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !deletedIds.contains(capsuleId), let cached = releasedMemory[capsuleId],
            cached.descriptorSHA256 == descriptorDigests[capsuleId] else { return nil }
        return cached.payload
    }
    public func isLocallyOpened(capsuleId: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !deletedIds.contains(capsuleId), let cached = releasedMemory[capsuleId],
            cached.descriptorSHA256 == descriptorDigests[capsuleId] else { return false }
        return cached.locallyOpened
    }
    public func isUnavailable(capsuleId: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidated || deletedIds.contains(capsuleId)
    }
    public func markLocallyOpened(envelope: CapsuleEnvelope) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !invalidated, releasedMemory[envelope.descriptor.capsuleId] != nil else { throw CapsuleError.cancelled }
        let released: CapsuleCachedRelease = try store.update { state in
            guard state.deletions[envelope.descriptor.capsuleId] == nil,
                var released = state.releases[envelope.descriptor.capsuleId],
                released.descriptorSHA256 == CapsuleCrypto.digest(envelope.descriptorBytes) else { throw CapsuleError.unavailable }
            released.locallyOpened = true
            state.releases[envelope.descriptor.capsuleId] = released
            return released
        }
        stateLock.lock(); releasedMemory[envelope.descriptor.capsuleId] = released; stateLock.unlock()
    }
    public func pendingOutbox() -> [CapsuleSealedMessage] {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !invalidated else { return [] }
        guard let state = try? store.read() else { return [] }
        stateLock.lock(); releasedMemory = state.releases; stateLock.unlock()
        return state.outbox.values.filter { !$0.enqueued }.compactMap { $0.sealed }
    }
    public func pendingOperationIds() -> [String] {
        guard let state = try? store.read() else { return [] }
        return state.outbox.values.filter { !$0.enqueued && $0.sealed == nil }.map { $0.operationId }
    }
    public func markEnqueued(operationId: String) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !invalidated else { throw CapsuleError.cancelled }
        try store.update { state in
            guard state.outbox[operationId] != nil else { throw CapsuleError.unavailable }
            // No sender plaintext/key is needed after native durable enqueue. Remove the operation.
            state.outbox.removeValue(forKey: operationId)
        }
    }

    /// Availability synchronization only. This endpoint cannot return a release key, and an
    /// account-wide opened acknowledgement never changes this device's local opened state.
    @discardableResult public func synchronizeMetadata(envelopes: [CapsuleEnvelope], completion: @escaping (Result<Set<String>, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        queue.async {
            do {
                guard envelopes.count <= 100 else { throw CapsuleError.invalidData }
                var expected: [String: CapsuleEnvelope] = [:]
                for envelope in envelopes {
                    let verified = try CapsuleEnvelopeCodec.verify(envelope.carrier, configuration: self.configuration)
                    guard verified.descriptorBytes == envelope.descriptorBytes,
                          verified.descriptor.senderId == self.accountId || verified.descriptor.recipientId == self.accountId else { throw CapsuleError.integrity }
                    expected[verified.descriptor.capsuleId] = verified
                }
                guard !expected.isEmpty else { self.deliver(cancellation, completion, .success([])); return }
                let body = try JSONSerialization.data(withJSONObject: ["capsule_ids": Array(expected.keys).sorted()])
                self.authenticated(path: "v1/capsules/metadata-batch", body: body, cancellation: cancellation) { [weak self] (result: Result<CapsuleMetadataResponse, Error>) in
                    guard let self else { return }
                    self.queue.async {
                        do {
                            let response = try result.get()
                            guard response.capsules.count <= expected.count else { throw CapsuleError.integrity }
                            var seen = Set<String>(), unavailable: [String: Int64] = [:]
                            for metadata in response.capsules {
                                guard let envelope = expected[metadata.capsuleId], seen.insert(metadata.capsuleId).inserted,
                                      metadata.revision > 0, ["sealed", "revoked"].contains(metadata.state),
                                      let carrier = metadata.carrier else { throw CapsuleError.integrity }
                                let verified = try CapsuleEnvelopeCodec.verify(carrier, configuration: self.configuration)
                                guard verified.descriptorBytes == envelope.descriptorBytes else { throw CapsuleError.integrity }
                                if metadata.hidden || metadata.state == "revoked" { unavailable[metadata.capsuleId] = metadata.revision }
                            }
                            guard !unavailable.isEmpty else {
                                self.deliver(cancellation, completion, .success([]))
                                return
                            }
                            let changed: Set<String> = try self.persist(cancellation: cancellation) { state in
                                var revisions = state.unavailableRevisions ?? [:], changed = Set<String>()
                                for (id, revision) in unavailable {
                                    if revisions[id] == nil { changed.insert(id) }
                                    revisions[id] = max(revisions[id] ?? 0, revision)
                                    state.releases.removeValue(forKey: id)
                                }
                                state.unavailableRevisions = revisions
                                return changed
                            }
                            self.stateLock.lock()
                            for id in unavailable.keys { self.deletedIds.insert(id); self.releasedMemory.removeValue(forKey: id) }
                            self.stateLock.unlock()
                            self.deliver(cancellation, completion, .success(changed))
                        } catch { self.deliver(cancellation, completion, .failure(error)) }
                    }
                }
            } catch { self.deliver(cancellation, completion, .failure(error)) }
        }
        return cancellation
    }

    @discardableResult public func synchronizeTime(completion: @escaping (Result<Void, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = CapsuleCancellation()
        stateLock.lock()
        if clock.hasVerifiedSample && CapsuleClock.continuousMs() - lastTimeRequest < 60_000 {
            stateLock.unlock(); deliver(cancellation, completion, .success(())); return cancellation
        }
        timeWaiters.append((cancellation, completion))
        if timeRequest != nil { stateLock.unlock(); return cancellation }
        let requestCancellation = CapsuleCancellation(); timeRequest = requestCancellation
        let currentGeneration = generation
        lastTimeRequest = CapsuleClock.continuousMs(); stateLock.unlock()
        api.request(path: "v1/time", method: "GET", cancellation: requestCancellation) { [weak self] (result: Result<CapsuleTimeResponse, Error>) in
            guard let self = self else { return }
            self.stateLock.lock()
            guard self.generation == currentGeneration, self.timeRequest === requestCancellation else { self.stateLock.unlock(); return }
            let waiters = self.timeWaiters; self.timeWaiters.removeAll(); self.timeRequest = nil; self.stateLock.unlock()
            for (waiter, callback) in waiters { self.deliver(waiter, callback, result.map { _ in () }) }
        }
        return cancellation
    }

    @discardableResult public func authStart(completion: @escaping (Result<CapsuleAuthStart, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        do {
            let rawVerifier = try CapsuleCrypto.random(32)
            let verifier = CapsuleWire.encode(rawVerifier)
            let body = try JSONSerialization.data(withJSONObject: ["completion_challenge": CapsuleCrypto.digest(rawVerifier)])
            api.request(path: "v1/auth/start", body: body, cancellation: cancellation) { [weak self] (result: Result<CapsuleAuthStartResponse, Error>) in
                guard let self = self else { return }
                let mapped = result.flatMap { response -> Result<CapsuleAuthStart, Error> in
                    guard response.authorizationURL.scheme == "https", CapsuleWire.validOpaqueId(response.transactionId) else { return .failure(CapsuleError.invalidData) }
                    return .success(CapsuleAuthStart(transactionId: response.transactionId, authorizationURL: response.authorizationURL, expiresMs: response.expiresMs, completionVerifier: verifier))
                }
                self.deliver(cancellation, completion, mapped)
            }
        } catch { deliver(cancellation, completion, .failure(error)) }
        return cancellation
    }

    @discardableResult public func authComplete(transaction: CapsuleAuthStart, completion: @escaping (Result<Bool, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        do {
            let body = try JSONSerialization.data(withJSONObject: ["transaction_id": transaction.transactionId, "completion_verifier": transaction.completionVerifier])
            api.request(path: "v1/auth/complete", body: body, cancellation: cancellation) { [weak self] (result: Result<CapsuleSession, Error>) in
                guard let self = self else { return }
                self.queue.async {
                    do {
                        switch result {
                        case let .success(session):
                            guard !cancellation.isCancelled else { throw CapsuleError.cancelled }
                            guard session.telegramId == self.accountId else { throw CapsuleError.accountMismatch }
                            guard !session.accessToken.isEmpty, !session.refreshToken.isEmpty, session.accessToken.utf8.count <= 512, session.refreshToken.utf8.count <= 512 else { throw CapsuleError.invalidData }
                            try self.persist(cancellation: cancellation) { $0.session = session }
                            self.deliver(cancellation, completion, .success(true))
                        case let .failure(error):
                            if case let CapsuleError.server(code, _, _) = error, ["pending", "authorization_pending", "login_pending"].contains(code) {
                                self.deliver(cancellation, completion, .success(false))
                            } else { throw error }
                        }
                    } catch { self.deliver(cancellation, completion, .failure(error)) }
                }
            }
        } catch { deliver(cancellation, completion, .failure(error)) }
        return cancellation
    }

    @discardableResult public func seal(payload: CapsulePayload, recipientId: String, durationSeconds: Int64, layout: CapsuleLayout, completion: @escaping (Result<CapsuleSealedMessage, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        queue.async {
            do {
                guard !cancellation.isCancelled else { throw CapsuleError.cancelled }
                try payload.validate(); try layout.validate()
                guard CapsuleWire.validUserId(recipientId), recipientId != self.accountId, (1...31_536_000).contains(durationSeconds) else { throw CapsuleError.invalidData }
                let operation: CapsuleOutboxOperation = try self.persist(cancellation: cancellation) { state in
                    if let existing = state.outbox.values.first(where: { !$0.enqueued && $0.recipientId == recipientId && $0.payload == payload && $0.durationSeconds == durationSeconds && $0.layout == layout }) { return existing }
                    let randomBytes = try CapsuleCrypto.random(8)
                    var randomId: Int64 = 0
                    for byte in randomBytes { randomId = (randomId &<< 8) | Int64(byte) }
                    let operation = CapsuleOutboxOperation(operationId: UUID().uuidString.lowercased(), nativeRandomId: randomId == 0 ? 1 : randomId, recipientId: recipientId, payload: payload, durationSeconds: durationSeconds, layout: layout, reservation: nil, encrypted: nil, sealed: nil, enqueued: false)
                    state.outbox[operation.operationId] = operation
                    return operation
                }
                self.resumeSealShared(operation: operation, subscriber: cancellation, completion: completion)
            } catch { self.deliver(cancellation, completion, .failure(error)) }
        }
        return cancellation
    }

    @discardableResult public func resumeSeal(operationId: String, completion: @escaping (Result<CapsuleSealedMessage, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        queue.async {
            do {
                guard let operation = try self.store.read().outbox[operationId] else { throw CapsuleError.unavailable }
                self.resumeSealShared(operation: operation, subscriber: cancellation, completion: completion)
            } catch { self.deliver(cancellation, completion, .failure(error)) }
        }
        return cancellation
    }

    private func resumeSealShared(operation: CapsuleOutboxOperation, subscriber: CapsuleCancellation, completion: @escaping (Result<CapsuleSealedMessage, Error>) -> Void) {
        stateLock.lock()
        guard !invalidated, !subscriber.isCancelled else { stateLock.unlock(); return }
        if sealWaiters[operation.operationId] != nil {
            sealWaiters[operation.operationId]?.append((subscriber, completion))
            stateLock.unlock()
            return
        }
        let request = trackedCancellation()
        let expectedGeneration = generation
        sealWaiters[operation.operationId] = [(subscriber, completion)]
        sealRequests[operation.operationId] = request
        stateLock.unlock()
        // Both foreground reconciliation and the composer can resume the same persisted intent.
        // One account-serialized request owns its reservation/encryption/upload until it finishes.
        resumeSeal(operation: operation, cancellation: request) { [weak self] result in
            guard let self else { return }
            self.stateLock.lock()
            guard self.generation == expectedGeneration, self.sealRequests[operation.operationId] === request else { self.stateLock.unlock(); return }
            let waiters = self.sealWaiters.removeValue(forKey: operation.operationId) ?? []
            self.sealRequests.removeValue(forKey: operation.operationId)
            self.stateLock.unlock()
            for (cancellation, callback) in waiters { self.deliver(cancellation, callback, result) }
            request.cancel()
        }
    }

    private func resumeSeal(operation: CapsuleOutboxOperation, cancellation: CapsuleCancellation, completion: @escaping (Result<CapsuleSealedMessage, Error>) -> Void) {
        if let sealed = operation.sealed { deliver(cancellation, completion, .success(sealed)); return }
        if operation.reservation != nil { uploadSeal(operation: operation, cancellation: cancellation, completion: completion); return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["recipient_id": operation.recipientId, "duration_s": operation.durationSeconds, "layout": try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation.layout))])
            authenticated(path: "v1/capsules/reserve", body: body, idempotencyKey: operation.operationId, cancellation: cancellation) { [weak self] (result: Result<CapsuleReserveResponse, Error>) in
                guard let self = self else { return }
                self.queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CapsuleError.cancelled }
                        let reservation = try result.get()
                        guard CapsuleWire.validOpaqueId(reservation.capsuleId) else { throw CapsuleError.invalidData }
                        let bindingBytes = try CapsuleWire.decode(reservation.bindingB64URL, maximum: 4096)
                        let binding = try CapsuleStrictJSON.decode(CapsuleBinding.self, from: bindingBytes)
                        guard binding.v == 1, binding.service == self.configuration.service,
                            binding.capsuleId == reservation.capsuleId, binding.senderId == self.accountId,
                            binding.recipientId == operation.recipientId, binding.durationSeconds == operation.durationSeconds,
                            binding.layout == operation.layout else { throw CapsuleError.integrity }
                        var updated = operation
                        updated.reservation = reservation
                        // Persist the one generated key/nonce/ciphertext before attempting upload.
                        updated.encrypted = try CapsuleCrypto.encrypt(operation.payload, binding: bindingBytes)
                        try self.persist(cancellation: cancellation) { $0.outbox[operation.operationId] = updated }
                        self.uploadSeal(operation: updated, cancellation: cancellation, completion: completion)
                    } catch { self.deliver(cancellation, completion, .failure(error)) }
                }
            }
        } catch { deliver(cancellation, completion, .failure(error)) }
    }

    private func uploadSeal(operation: CapsuleOutboxOperation, cancellation: CapsuleCancellation, completion: @escaping (Result<CapsuleSealedMessage, Error>) -> Void) {
        do {
            guard let reservation = operation.reservation, let encrypted = operation.encrypted else { throw CapsuleError.unavailable }
            let body = try JSONEncoder().encode(encrypted)
            authenticated(path: "v1/capsules/\(reservation.capsuleId)/seal", body: body, idempotencyKey: operation.operationId, cancellation: cancellation) { [weak self] (result: Result<CapsuleSealResponse, Error>) in
                guard let self = self else { return }
                self.queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CapsuleError.cancelled }
                        let response = try result.get()
                        let context = CapsuleMessageContext(accountId: self.accountId, senderId: self.accountId, peerId: operation.recipientId, isOutgoing: true, isForwarded: false, isDirectCloudChat: true)
                        let envelope = try self.verify(carrier: response.carrier, context: context)
                        guard envelope.descriptor.capsuleId == reservation.capsuleId,
                            envelope.descriptor.bindingSHA256 == encrypted.bindingSHA256,
                            envelope.descriptor.layout == operation.layout,
                            envelope.descriptor.durationSeconds == operation.durationSeconds,
                            envelope.descriptor.payloadSHA256 == CapsuleCrypto.digest(try CapsuleWire.decode(encrypted.nonce, maximum: 12) + CapsuleWire.decode(encrypted.ciphertext, maximum: 65536) + CapsuleWire.decode(encrypted.tag, maximum: 16)) else { throw CapsuleError.integrity }
                        let sealed = CapsuleSealedMessage(operationId: operation.operationId, capsuleId: reservation.capsuleId, recipientId: operation.recipientId, carrier: response.carrier, nativeRandomId: operation.nativeRandomId)
                        try self.persist(cancellation: cancellation) { state in
                            var updated = operation; updated.sealed = sealed
                            state.outbox[operation.operationId] = updated
                        }
                        self.deliver(cancellation, completion, .success(sealed))
                    } catch {
                        if case let CapsuleError.server(code, _, _) = error, code == "reservation_expired" {
                            // The service has authoritatively confirmed this reservation never
                            // sealed. Retire only that unsent intent so an explicit retry can
                            // reserve fresh metadata instead of looping on the same expired ID.
                            try? self.persist(cancellation: cancellation) { state in
                                if state.outbox[operation.operationId]?.sealed == nil {
                                    state.outbox.removeValue(forKey: operation.operationId)
                                }
                            }
                        }
                        self.deliver(cancellation, completion, .failure(error))
                    }
                }
            }
        } catch { deliver(cancellation, completion, .failure(error)) }
    }

    @discardableResult public func open(envelope: CapsuleEnvelope, context: CapsuleMessageContext, completion: @escaping (Result<CapsulePayload, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        do {
            guard context.accountId == accountId else { throw CapsuleError.accountMismatch }
            let verified = try verify(carrier: envelope.carrier, context: context)
            guard verified.descriptorBytes == envelope.descriptorBytes, verified.descriptor == envelope.descriptor else { throw CapsuleError.integrity }
        }
        catch { deliver(cancellation, completion, .failure(error)); return cancellation }
        let id = envelope.descriptor.capsuleId
        stateLock.lock()
        guard !deletedIds.contains(id) else { stateLock.unlock(); deliver(cancellation, completion, .failure(CapsuleError.unavailable)); return cancellation }
        let currentGeneration = generation
        if openWaiters[id] != nil { openWaiters[id]?.append((cancellation, completion)); stateLock.unlock(); return cancellation }
        openWaiters[id] = [(cancellation, completion)]
        stateLock.unlock()
        queue.async {
            do {
                if let cached = try self.store.read().releases[id], cached.descriptorSHA256 == CapsuleCrypto.digest(envelope.descriptorBytes) {
                    self.finishOpen(id: id, generation: currentGeneration, result: .success(cached.payload)); return
                }
                let body = try JSONSerialization.data(withJSONObject: ["open_operation_id": UUID().uuidString.lowercased(), "known_revision": 1])
                // Shared transport is not cancelled by a recycled subscriber. It may cache a release,
                // but no opening bit or UI reveal is committed by network completion.
                let requestCancellation = self.trackedCancellation()
                self.authenticated(path: "v1/capsules/\(id)/release", body: body, cancellation: requestCancellation) { [weak self] (result: Result<CapsuleReleaseResponse, Error>) in
                    guard let self = self else { return }
                    self.queue.async {
                        do {
                            let response = try result.get()
                            let payload = try CapsuleCrypto.decrypt(response, envelope: envelope)
                            self.stateLock.lock(); let valid = self.generation == currentGeneration && !self.deletedIds.contains(id); self.stateLock.unlock()
                            guard valid else { throw CapsuleError.cancelled }
                            let cached: CapsuleCachedRelease = try self.persist(cancellation: requestCancellation) { state in
                                guard state.deletions[id] == nil else { throw CapsuleError.unavailable }
                                let cached = CapsuleCachedRelease(descriptorSHA256: CapsuleCrypto.digest(envelope.descriptorBytes), payload: payload, locallyOpened: false)
                                state.releases[id] = cached
                                return cached
                            }
                            self.stateLock.lock()
                            if self.generation == currentGeneration { self.releasedMemory[id] = cached }
                            self.stateLock.unlock()
                            self.finishOpen(id: id, generation: currentGeneration, result: .success(payload))
                        } catch { self.finishOpen(id: id, generation: currentGeneration, result: .failure(error)) }
                        requestCancellation.cancel()
                    }
                }
            } catch { self.finishOpen(id: id, generation: currentGeneration, result: .failure(error)) }
        }
        return cancellation
    }

    private func finishOpen(id: String, generation expected: UInt64, result: Result<CapsulePayload, Error>) {
        stateLock.lock()
        guard generation == expected else { stateLock.unlock(); return }
        let waiters = openWaiters.removeValue(forKey: id) ?? []
        let valid = !deletedIds.contains(id)
        stateLock.unlock()
        for (cancellation, completion) in waiters { deliver(cancellation, completion, valid ? result : .failure(CapsuleError.cancelled)) }
    }

    @discardableResult public func delete(envelope: CapsuleEnvelope, forEveryone: Bool, completion: @escaping (Result<Void, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        let id = envelope.descriptor.capsuleId
        guard envelope.descriptor.senderId == accountId || envelope.descriptor.recipientId == accountId,
            !forEveryone || envelope.descriptor.senderId == accountId else { deliver(cancellation, completion, .failure(CapsuleError.unavailable)); return cancellation }
        stateLock.lock(); deletedIds.insert(id); releasedMemory.removeValue(forKey: id); stateLock.unlock()
        queue.async {
            do {
                let intent: CapsuleDeletionIntent = try self.persist(cancellation: cancellation) { state in
                    state.releases.removeValue(forKey: id)
                    let existing = state.deletions[id]
                    let intent: CapsuleDeletionIntent
                    if let existing = existing, existing.forEveryone || !forEveryone {
                        intent = existing
                    } else {
                        // A failed hide can be strengthened to revoke; never silently downgrade intent.
                        intent = CapsuleDeletionIntent(capsuleId: id, forEveryone: forEveryone, operationId: UUID().uuidString.lowercased())
                    }
                    state.deletions[id] = intent
                    return intent
                }
                self.submitDelete(intent: intent, cancellation: cancellation) { result in
                    self.deliver(cancellation, completion, result)
                }
            } catch { self.deliver(cancellation, completion, .failure(error)) }
        }
        return cancellation
    }
    /// Retry only unacknowledged service mutations. A successful tombstone remains durable but
    /// is not uploaded on every foreground transition. This does not delete native Telegram rows.
    @discardableResult public func resumePendingDeletions(completion: @escaping (Result<Void, Error>) -> Void) -> CapsuleCancellation {
        let cancellation = trackedCancellation()
        queue.async {
            do {
                let intents = try self.store.read().deletions.values.filter { $0.acknowledged != true }
                    .sorted { $0.operationId < $1.operationId }.prefix(100)
                let pending = Array(intents)
                func next(_ index: Int) {
                    guard !cancellation.isCancelled else { return }
                    guard index < pending.count else { self.deliver(cancellation, completion, .success(())); return }
                    self.submitDelete(intent: pending[index], cancellation: cancellation) { result in
                        switch result {
                        case .success: next(index + 1)
                        case .failure: self.deliver(cancellation, completion, result)
                        }
                    }
                }
                next(0)
            } catch { self.deliver(cancellation, completion, .failure(error)) }
        }
        return cancellation
    }
    private func submitDelete(intent: CapsuleDeletionIntent, cancellation: CapsuleCancellation, completion: @escaping (Result<Void, Error>) -> Void) {
        if intent.acknowledged == true { completion(.success(())); return }
        let operation = intent.forEveryone ? "revoke" : "hide"
        authenticated(path: "v1/capsules/\(intent.capsuleId)/\(operation)", body: Data("{}".utf8), idempotencyKey: intent.operationId, cancellation: cancellation) { [weak self] (result: Result<CapsuleEmptyResponse, Error>) in
            guard let self = self else { return }
            self.queue.async {
                do {
                    _ = try result.get()
                    try self.persist(cancellation: cancellation) { state in
                        if var current = state.deletions[intent.capsuleId], current.operationId == intent.operationId {
                            current.acknowledged = true
                            state.deletions[intent.capsuleId] = current
                        }
                    }
                    // Keep the tombstone permanently so stale callbacks cannot revive it.
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
    }

    /// Cancel foreground account work on account switch/background. Durable released/opened state remains.
    public func cancelActiveWork() {
        stateLock.lock()
        generation &+= 1
        let cancellations = Array(active.values); active.removeAll()
        let waiters = openWaiters; openWaiters.removeAll(); verified.removeAll()
        let timeCancellation = timeRequest; timeRequest = nil; timeWaiters.removeAll()
        let refreshCancellation = refreshRequest; refreshRequest = nil; refreshWaiters.removeAll()
        let sealCancellations = Array(sealRequests.values)
        sealRequests.removeAll(); sealWaiters.removeAll()
        releasedMemory.removeAll(); descriptorDigests.removeAll()
        stateLock.unlock()
        for cancellation in cancellations { cancellation.cancel() }
        timeCancellation?.cancel()
        refreshCancellation?.cancel()
        for cancellation in sealCancellations { cancellation.cancel() }
        for callbacks in waiters.values { for (cancellation, _) in callbacks { cancellation.cancel() } }
    }
    public func clearMemory() { cancelActiveWork() }
    public func lockProtectedMemory() { clearMemory() }
    public func releaseRegistryReference() {
        Self.registryLock.lock()
        let key = configuration.service + ":" + accountId
        if Self.registry[key] === self { Self.registry.removeValue(forKey: key) }
        Self.registryLock.unlock()
    }
    public func logout() throws {
        stateLock.lock(); invalidated = true; stateLock.unlock()
        let session = try? store.read().session
        cancelActiveWork()
        if let session = session {
            api.request(path: "v1/auth/logout", body: Data("{}".utf8), token: session.accessToken, cancellation: CapsuleCancellation()) { (_: Result<CapsuleEmptyResponse, Error>) in }
        }
        try store.destroy()
        Self.registryLock.lock()
        let key = configuration.service + ":" + accountId
        if Self.registry[key] === self { Self.registry.removeValue(forKey: key) }
        Self.registryLock.unlock()
    }

    private func authenticated<T: Decodable>(path: String, body: Data, idempotencyKey: String? = nil, cancellation: CapsuleCancellation, completion: @escaping (Result<T, Error>) -> Void) {
        do {
            guard let session = try store.read().session, session.telegramId == accountId else { throw CapsuleError.notAuthenticated }
            if session.accessExpiresMs <= clock.estimatedServerMs + 30_000 {
                refresh(session: session, cancellation: cancellation) { result in
                    switch result {
                    case let .success(refreshed): self.api.request(path: path, body: body, token: refreshed.accessToken, idempotencyKey: idempotencyKey, cancellation: cancellation, completion: completion)
                    case let .failure(error): completion(.failure(error))
                    }
                }
            } else {
                api.request(path: path, body: body, token: session.accessToken, idempotencyKey: idempotencyKey, cancellation: cancellation) { (result: Result<T, Error>) in
                    if case let .failure(error) = result, case CapsuleError.notAuthenticated = error {
                        self.refresh(session: session, cancellation: cancellation) { refreshed in
                            switch refreshed {
                            case let .success(updated): self.api.request(path: path, body: body, token: updated.accessToken, idempotencyKey: idempotencyKey, cancellation: cancellation, completion: completion)
                            case let .failure(failure): completion(.failure(failure))
                            }
                        }
                    } else { completion(result) }
                }
            }
        } catch { completion(.failure(error)) }
    }
    private func refresh(session: CapsuleSession, cancellation: CapsuleCancellation, completion: @escaping (Result<CapsuleSession, Error>) -> Void) {
        if let current = try? store.read().session, current.refreshToken != session.refreshToken { completion(.success(current)); return }
        stateLock.lock()
        refreshWaiters.append((cancellation, completion))
        if refreshRequest != nil { stateLock.unlock(); return }
        let requestCancellation = trackedCancellation()
        refreshRequest = requestCancellation
        stateLock.unlock()
        do {
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
            api.request(path: "v1/auth/refresh", body: body, cancellation: requestCancellation) { [weak self] (result: Result<CapsuleSession, Error>) in
                guard let self = self else { return }
                self.queue.async {
                    let resultOutcome: Result<CapsuleSession, Error>
                    do {
                        guard !requestCancellation.isCancelled else { throw CapsuleError.cancelled }
                        let refreshed = try result.get()
                        guard refreshed.telegramId == self.accountId else { throw CapsuleError.accountMismatch }
                        try self.persist(cancellation: requestCancellation) { state in
                            guard state.session?.refreshToken == session.refreshToken else { throw CapsuleError.cancelled }
                            state.session = refreshed
                        }
                        resultOutcome = .success(refreshed)
                    } catch { resultOutcome = .failure(error) }
                    self.finishRefresh(resultOutcome, request: requestCancellation)
                    requestCancellation.cancel()
                }
            }
        } catch { finishRefresh(.failure(error), request: requestCancellation); requestCancellation.cancel() }
    }
    private func finishRefresh(_ result: Result<CapsuleSession, Error>, request: CapsuleCancellation) {
        stateLock.lock()
        guard refreshRequest === request else { stateLock.unlock(); return }
        let waiters = refreshWaiters; refreshWaiters.removeAll(); refreshRequest = nil; stateLock.unlock()
        for (cancellation, completion) in waiters where !cancellation.isCancelled { completion(result) }
    }
    private func trackedCancellation() -> CapsuleCancellation {
        let cancellation = CapsuleCancellation(), id = UUID()
        stateLock.lock()
        if invalidated { stateLock.unlock(); cancellation.cancel(); return cancellation }
        active[id] = cancellation; stateLock.unlock()
        cancellation.add { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self.active.removeValue(forKey: id); self.stateLock.unlock()
        }
        return cancellation
    }
    @discardableResult private func persist<T>(cancellation: CapsuleCancellation, _ body: (inout CapsuleStoreState) throws -> T) throws -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !invalidated, !cancellation.isCancelled else { throw CapsuleError.cancelled }
        return try store.update(body)
    }
    private func deliver<T>(_ cancellation: CapsuleCancellation, _ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
        stateLock.lock(); let expectedGeneration = generation; stateLock.unlock()
        DispatchQueue.main.async {
            self.stateLock.lock()
            for id in self.active.filter({ $0.value === cancellation }).keys { self.active.removeValue(forKey: id) }
            let valid = !self.invalidated && self.generation == expectedGeneration
            self.stateLock.unlock()
            if valid && !cancellation.isCancelled { completion(result) }
        }
    }
}
