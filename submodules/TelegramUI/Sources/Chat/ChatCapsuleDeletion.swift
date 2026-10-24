import Foundation
import SwiftSignalKit
import TelegramCore
import TimeCapsuleCore
import TimeCapsuleSummary
import UndoUI

extension ChatControllerImpl {
    /// Finish service revocation/hiding before committing native deletion. A failed operation
    /// leaves the row available for retry and the durable service tombstone prevents resurrection.
    func prepareCapsuleDeletion(messageIds: Set<EngineMessage.Id>, type: InteractiveMessagesDeletionType, completion: @escaping (Bool, Bool) -> Void) {
        guard !messageIds.isEmpty else { completion(true, false); return }
        // Resolve from durable message storage: selected rows can be outside the current viewport.
        let _ = (combineLatest(messageIds.map { id in
            self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id))
        }) |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            guard let self else { completion(false, false); return }
            self.prepareLoadedCapsuleDeletion(messages: messages.compactMap { $0 }, type: type, completion: completion)
        })
    }

    private func prepareLoadedCapsuleDeletion(messages: [EngineMessage], type: InteractiveMessagesDeletionType, completion: @escaping (Bool, Bool) -> Void) {
        let messages = messages.filter { CapsuleSafeSummary.isCarrier($0.text) }
        guard !messages.isEmpty else { completion(true, false); return }
        let accountId = String(self.context.account.peerId.id._internalGetInt64Value())
        guard let service = CapsuleService.configured(accountId: accountId) else {
            self.presentCapsuleDeletionError()
            completion(false, false)
            return
        }
        var envelopes: [CapsuleEnvelope] = []
        for message in messages {
            let context = CapsuleMessageContext(accountId: accountId,
                senderId: String(message.author?.id.id._internalGetInt64Value() ?? 0),
                peerId: String(message.id.peerId.id._internalGetInt64Value()),
                isOutgoing: !message.effectivelyIncoming(self.context.account.peerId),
                isForwarded: message.forwardInfo != nil,
                isDirectCloudChat: message.id.peerId.namespace == Namespaces.Peer.CloudUser)
            if let envelope = try? service.verify(carrier: message.text, context: context) {
                envelopes.append(envelope)
            }
        }
        func deleteNext(_ index: Int) {
            guard index < envelopes.count else { completion(true, !envelopes.isEmpty); return }
            let envelope = envelopes[index]
            let revoke: Bool
            if case .forEveryone = type {
                revoke = envelope.descriptor.senderId == accountId
            } else {
                revoke = false
            }
            service.delete(envelope: envelope, forEveryone: revoke) { [weak self] result in
                switch result {
                case .success:
                    deleteNext(index + 1)
                case .failure:
                    self?.presentCapsuleDeletionError()
                    completion(false, false)
                }
            }
        }
        deleteNext(0)
    }

    private func presentCapsuleDeletionError() {
        self.controllerInteraction?.displayUndo(.info(title: nil, text: self.presentationData.strings.TimeCapsule_DeleteFailed, timeout: nil, customUndoText: nil))
    }
}
