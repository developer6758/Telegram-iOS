import AccountContext
import AlertUI
import Display
import Foundation
import InteractiveTextComponent
import OverlayStatusController
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import TimeCapsuleAuthorizationUI
import TimeCapsuleCore
import UIKit

/// Eligibility is checked when building the menu and again immediately before a seal/send.
/// No persistent flag can change the meaning of the next ordinary Send press.
private func chatTimeCapsuleEligible(_ controller: ChatControllerImpl) -> Bool {
    let state = controller.presentationInterfaceState
    guard case let .peer(peerId) = controller.chatLocation,
        peerId.namespace == Namespaces.Peer.CloudUser,
        peerId != controller.context.account.peerId,
        let user = state.renderedPeer?.peer as? TelegramUser,
        user.botInfo == nil,
        !isServicePeer(user),
        !user.isDeleted,
        state.subject == nil,
        state.currentSendAsPeerId == nil,
        state.sendPaidMessageStars == nil,
        state.interfaceState.editMessage == nil,
        state.interfaceState.replyMessageSubject == nil,
        state.interfaceState.postSuggestionState == nil,
        state.interfaceState.mediaDraftState == nil,
        state.interfaceState.forwardMessageIds?.isEmpty != false,
        state.inputTextPanelState.mediaRecordingState == nil,
        controller.audioRecorderValue == nil,
        controller.videoRecorderValue == nil else {
        return false
    }
    let content = controller.chatDisplayNode.textInputPanelNode?.inputTextState.content ?? state.interfaceState.composeInputState.content
    guard !content.isEmpty else { return false }
    // Ordinary paragraphs and native preformatted code are text-only capsule payloads.
    // Other structural content and custom emoji media retain their original draft unchanged.
    return content.blocks.allSatisfy { block in
        let runs: [ChatInputRun]
        switch block {
        case let .paragraph(paragraph):
            guard case .body = paragraph.style, paragraph.list == nil else { return false }
            runs = paragraph.runs
        case let .code(code):
            runs = code.runs
        default:
            return false
        }
        return runs.allSatisfy { run in
            if run.attributes.formula != nil { return false }
            if case .customEmoji = run.attributes.entity { return false }
            if case .button = run.attributes.entity { return false }
            return true
        }
    }
}

func chatTimeCapsuleMenuAction(controller: ChatControllerImpl) -> (() -> Void)? {
    guard chatTimeCapsuleEligible(controller) else { return nil }
    return { [weak controller] in
        guard let controller, chatTimeCapsuleEligible(controller) else { return }
        let input = controller.chatDisplayNode.textInputPanelNode?.inputTextState ?? controller.presentationInterfaceState.interfaceState.composeInputState
        let accountId = String(controller.context.account.peerId.id._internalGetInt64Value())
        guard let service = CapsuleService.configured(accountId: accountId) else {
            controller.present(textAlertController(context: controller.context, title: controller.presentationData.strings.TimeCapsule_Title, text: controller.presentationData.strings.TimeCapsule_NotConfigured, actions: [TextAlertAction(type: .defaultAction, title: controller.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            return
        }
        let payload: CapsulePayload
        do {
            payload = try chatTimeCapsulePayload(content: input.content)
        } catch {
            let strings = controller.presentationData.strings
            controller.present(textAlertController(context: controller.context, title: strings.TimeCapsule_Title, text: strings.TimeCapsule_UnsupportedFormatting, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: { [weak controller] in
                    controller?.chatDisplayNode.textInputPanelNode?.ensureFocused()
                }),
                TextAlertAction(type: .defaultAction, title: strings.TimeCapsule_ConvertPlainText, action: { [weak controller] in
                    guard let controller else { return }
                    let payload = CapsulePayload(text: input.content.plainText)
                    guard (try? payload.validate()) != nil else { return }
                    chatTimeCapsulePresentDuration(controller: controller, input: input, payload: payload, service: service)
                })
            ]), in: .window(.root))
            return
        }
        chatTimeCapsulePresentDuration(controller: controller, input: input, payload: payload, service: service)
    }
}

private func chatTimeCapsulePresentDuration(controller: ChatControllerImpl, input: ChatTextInputState, payload: CapsulePayload, service: CapsuleService) {
    controller.view.endEditing(true)
    let sheet = chatTimeCapsuleDurationController(presentationData: controller.presentationData, send: { [weak controller] duration in
        guard let controller else { return }
        ChatTimeCapsuleComposerOperation(controller: controller, input: input, payload: payload, duration: duration, service: service).start()
    }, cancelled: { [weak controller] in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            controller?.chatDisplayNode.textInputPanelNode?.ensureFocused()
        }
    })
    controller.present(sheet, in: .window(.root))
}

private enum CapsuleComposeError: Error { case unsupported }

private func chatTimeCapsulePayload(content: ChatInputContent) throws -> CapsulePayload {
    var text = ""
    var entities: [CapsuleEntity] = []
    for (index, block) in content.blocks.enumerated() {
        if index != 0 { text += "\n" }
        if case let .code(code) = block {
            guard code.runs.allSatisfy({ $0.attributes.entity == nil && $0.attributes.formula == nil }) else { throw CapsuleComposeError.unsupported }
            let offset = text.utf16.count
            text += code.text
            let length = code.text.utf16.count
            if length != 0 {
                entities.append(CapsuleEntity(type: "pre", offset: offset, length: length, language: chatInputCodeLanguageForSending(code.language)))
            }
            continue
        }
        guard case let .paragraph(paragraph) = block else { throw CapsuleComposeError.unsupported }
        for run in paragraph.runs {
            let offset = text.utf16.count
            let length = run.text.utf16.count
            text += run.text
            guard length != 0 else { continue }
            let attributes = run.attributes
            let flags: [(String, Bool)] = [("bold", attributes.bold), ("italic", attributes.italic), ("underline", attributes.underline), ("strike", attributes.strikethrough), ("code", attributes.monospace), ("spoiler", attributes.spoiler)]
            for (type, enabled) in flags where enabled {
                entities.append(CapsuleEntity(type: type, offset: offset, length: length))
            }
            if let entity = attributes.entity {
                guard case let .url(url) = entity else { throw CapsuleComposeError.unsupported }
                entities.append(CapsuleEntity(type: "text_url", offset: offset, length: length, url: url))
            }
        }
    }
    let payload = CapsulePayload(text: text, entities: entities)
    try payload.validate()
    return payload
}

/// A bounded, account-scoped operation retains itself only while its explicit Send Capsule intent
/// is active. The source draft is neither enqueued nor cleared until carrier enqueue is durable.
private final class ChatTimeCapsuleComposerOperation {
    private weak var controller: ChatControllerImpl?
    private let input: ChatTextInputState
    private let payload: CapsulePayload
    private let duration: Int64
    private let service: CapsuleService
    private let accountId: String
    private let peerId: EnginePeer.Id
    private var authorization: CapsuleAuthorizationSession?
    private var request: CapsuleCancellation?
    private var enqueue: Disposable?
    private var overlay: ViewController?
    private var keepAlive: ChatTimeCapsuleComposerOperation?
    private var finished = false
    private var backgroundObserver: NSObjectProtocol?

    init(controller: ChatControllerImpl, input: ChatTextInputState, payload: CapsulePayload, duration: Int64, service: CapsuleService) {
        self.controller = controller
        self.input = input
        self.payload = payload
        self.duration = duration
        self.service = service
        self.accountId = String(controller.context.account.peerId.id._internalGetInt64Value())
        self.peerId = controller.chatLocation.peerId!
    }

    func start() {
        guard let controller = self.controller, chatTimeCapsuleEligible(controller), (1...31_536_000).contains(self.duration) else { return }
        self.keepAlive = self
        if self.service.hasSession {
            self.seal()
        } else if let anchor = controller.view.window {
            let authorization = CapsuleAuthorizationSession(service: self.service, anchor: anchor) { [weak self] result in
                guard let self, !self.finished else { return }
                self.authorization = nil
                switch result {
                case .success: self.seal()
                case let .failure(error):
                    if let authorizationError = error as? CapsuleAuthorizationError, case .cancelled = authorizationError {
                        self.finish(showError: false)
                    } else {
                        self.finish(showError: true)
                    }
                }
            }
            self.authorization = authorization
            authorization.start()
        } else {
            self.finish(showError: true)
        }
    }

    private func seal() {
        guard let controller = self.controller, chatTimeCapsuleEligible(controller), self.accountId == String(controller.context.account.peerId.id._internalGetInt64Value()), self.peerId == controller.chatLocation.peerId else {
            self.finish(showError: false)
            return
        }
        let overlay = OverlayStatusController(theme: controller.presentationData.theme, type: .loading(cancelled: { [weak self] in
            self?.finish(showError: false)
        }))
        self.overlay = overlay
        controller.present(overlay, in: .window(.root))
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish(showError: false)
        }
        let fontSize = CGFloat(controller.presentationData.chatFontSize.baseDisplaySize)
        let payload = self.payload
        // Use the native Display text layout engine on a worker queue; only the coarse rounded
        // bounds leave the device. Text/bitmap/glyph positions are never in layout metadata.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layout = chatTimeCapsuleMeasure(payload: payload, fontSize: fontSize)
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                self.request = self.service.seal(payload: payload, recipientId: String(self.peerId.id._internalGetInt64Value()), durationSeconds: self.duration, layout: layout) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, !self.finished else { return }
                        self.request = nil
                        switch result {
                        case let .success(message): self.enqueue(message)
                        case .failure: self.finish(showError: true)
                        }
                    }
                }
            }
        }
    }

    private func enqueue(_ message: CapsuleSealedMessage) {
        guard let controller = self.controller, chatTimeCapsuleEligible(controller), self.peerId == controller.chatLocation.peerId,
            self.accountId == String(controller.context.account.peerId.id._internalGetInt64Value()),
            message.carrier.utf16.count <= min(3500, Int(controller.context.userLimits.maxMessageLength)) else {
            self.finish(showError: true)
            return
        }
        self.enqueue = (controller.context.engine.messages.enqueueTimeCapsuleCarrier(to: self.peerId, carrier: message.carrier, randomId: message.nativeRandomId)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] id in
            guard let self, !self.finished else { return }
            guard id != nil else { self.finish(showError: true); return }
            // Enqueue is already durable. If updating the side store fails, recovery repeats the
            // same random ID and the native transaction returns this existing message.
            let _ = try? self.service.markEnqueued(operationId: message.operationId)
            if let controller = self.controller {
                // Do not erase edits made after the sheet opened or an unrelated later draft.
                let current = controller.chatDisplayNode.textInputPanelNode?.inputTextState ?? controller.presentationInterfaceState.interfaceState.composeInputState
                if current.content == self.input.content {
                    controller.updateChatPresentationInterfaceState(animated: true, interactive: false, { state in
                        return state.updatedInterfaceState { $0.withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))).withUpdatedSendMessageEffect(nil) }
                    })
                }
                controller.commitPurposefulAction()
                controller.chatDisplayNode.historyNode.scrollToEndOfHistory()
            }
            self.finish(showError: false)
        })
    }

    private func finish(showError: Bool) {
        guard !self.finished else { return }
        self.finished = true
        self.request?.cancel()
        self.request = nil
        self.enqueue?.dispose()
        self.enqueue = nil
        self.authorization?.cancel()
        self.authorization = nil
        if let backgroundObserver = self.backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        self.overlay?.dismiss()
        self.overlay = nil
        if let controller = self.controller, showError {
            let strings = controller.presentationData.strings
            controller.present(textAlertController(context: controller.context, title: strings.TimeCapsule_Title, text: strings.TimeCapsule_SendFailed, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: { [weak controller] in
                controller?.chatDisplayNode.textInputPanelNode?.ensureFocused()
            })]), in: .window(.root))
        } else if let controller = self.controller, UIApplication.shared.applicationState == .active {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak controller] in
                guard let controller, controller.view.window != nil else { return }
                controller.chatDisplayNode.textInputPanelNode?.ensureFocused()
            }
        }
        self.keepAlive = nil
    }
}

private func chatTimeCapsuleMeasure(payload: CapsulePayload, fontSize: CGFloat) -> CapsuleLayout {
    let entities: [MessageTextEntity] = payload.entities.compactMap { entity in
        let type: MessageTextEntityType
        switch entity.type {
        case "bold": type = .Bold
        case "italic": type = .Italic
        case "underline": type = .Underline
        case "strike": type = .Strikethrough
        case "code": type = .Code
        case "pre": type = .Pre(language: entity.language)
        case "spoiler": type = .Spoiler
        case "text_url":
            guard let url = entity.url else { return nil }
            type = .TextUrl(url: url)
        default: return nil
        }
        return MessageTextEntity(range: entity.offset ..< (entity.offset + entity.length), type: type)
    }
    // Use the same attributed text builder, fonts and layout engine as an ordinary text bubble.
    let attributed = stringWithAppliedEntities(payload.text, entities: entities, baseColor: .black, linkColor: .black, baseFont: Font.regular(fontSize), linkFont: Font.regular(fontSize), boldFont: Font.bold(fontSize), italicFont: Font.italic(fontSize), boldItalicFont: Font.semiboldItalic(fontSize), fixedFont: Font.monospace(fontSize), blockQuoteFont: Font.regular(fontSize - 1.0), message: nil)
    let makeLayout = InteractiveTextNodeWithEntities.asyncLayout(nil)
    let samples = [14.0, 20.0, 28.0].map { constraint -> CapsuleLayoutSample in
        let (layout, _) = makeLayout(InteractiveTextNodeLayoutArguments(attributedString: attributed, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: CGFloat(constraint) * fontSize, height: 512.0 * fontSize), alignment: .natural, insets: .zero))
        let width = min(constraint, max(0.25, ceil(Double(layout.size.width / fontSize) * 4.0) / 4.0))
        let height = min(512.0, max(0.25, ceil(Double(layout.size.height / fontSize) * 4.0) / 4.0))
        return CapsuleLayoutSample(constraintEm: constraint, widthEm: width, heightEm: height)
    }
    return CapsuleLayout(samples: samples)
}
