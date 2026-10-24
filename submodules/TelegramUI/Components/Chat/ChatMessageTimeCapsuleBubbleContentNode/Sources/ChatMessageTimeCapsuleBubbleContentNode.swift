import Foundation
import UIKit
import AsyncDisplayKit
import Display
import LottieSettings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TimeCapsuleCore
import TimeCapsuleAuthorizationUI
import ChatMessageBubbleContentNode
import ChatMessageTextBubbleContentNode
import ChatMessageDateAndStatusNode
import ChatMessageItemCommon

public func timeCapsuleMessageContext(accountPeerId: EnginePeer.Id, message: EngineRawMessage) -> CapsuleMessageContext {
    return CapsuleMessageContext(
        accountId: String(accountPeerId.id._internalGetInt64Value()),
        senderId: message.author.map { String($0.id.id._internalGetInt64Value()) } ?? "",
        peerId: String(message.id.peerId.id._internalGetInt64Value()),
        isOutgoing: !message.effectivelyIncoming(accountPeerId),
        isForwarded: message.forwardInfo != nil,
        isDirectCloudChat: message.id.peerId.namespace == Namespaces.Peer.CloudUser && message.threadId == nil && message.media.isEmpty
    )
}

/// One coalesced timer per account, holding only weak views. Ticks change labels, never layout or
/// networking. A deadline is a presentation event; only the explicit activation path releases keys.
private final class CapsuleVisibleTickScheduler {
    private final class WeakNode {
        weak var node: ChatMessageTimeCapsuleBubbleContentNode?
        init(_ node: ChatMessageTimeCapsuleBubbleContentNode) { self.node = node }
    }
    private static var accounts: [String: CapsuleVisibleTickScheduler] = [:]
    private var nodes: [ObjectIdentifier: WeakNode] = [:]
    private var timer: Foundation.Timer?
    private var metadataRequest: CapsuleCancellation?
    private var metadataScheduled = false
    private var metadataNeedsResync = false

    static func add(_ node: ChatMessageTimeCapsuleBubbleContentNode, accountId: String) {
        assert(Thread.isMainThread)
        let scheduler: CapsuleVisibleTickScheduler
        if let current = self.accounts[accountId] {
            scheduler = current
        } else {
            scheduler = CapsuleVisibleTickScheduler()
            self.accounts[accountId] = scheduler
        }
        scheduler.nodes[ObjectIdentifier(node)] = WeakNode(node)
        scheduler.scheduleMetadata()
        scheduler.updateTimer()
    }

    private func updateTimer() {
        self.nodes = self.nodes.filter { $0.value.node != nil }
        let needsTimer = self.nodes.values.contains { $0.node?.opened == false }
        if !needsTimer {
            self.timer?.invalidate()
            self.timer = nil
        } else if self.timer == nil {
            let scheduler = self
            let timer = Foundation.Timer(timeInterval: 1.0, repeats: true, block: { [weak scheduler] _ in
                guard let scheduler else { return }
                scheduler.nodes = scheduler.nodes.filter { $0.value.node != nil }
                for value in scheduler.nodes.values { value.node?.tick() }
                scheduler.updateTimer()
            })
            timer.tolerance = 0.08
            RunLoop.main.add(timer, forMode: .common)
            scheduler.timer = timer
        }
    }

    static func remove(_ node: ChatMessageTimeCapsuleBubbleContentNode, accountId: String) {
        self.remove(id: ObjectIdentifier(node), accountId: accountId)
    }

    static func remove(id: ObjectIdentifier, accountId: String) {
        assert(Thread.isMainThread)
        guard let scheduler = self.accounts[accountId] else { return }
        scheduler.nodes.removeValue(forKey: id)
        scheduler.updateTimer()
        if scheduler.nodes.isEmpty {
            scheduler.timer?.invalidate()
            scheduler.timer = nil
            scheduler.metadataRequest?.cancel()
            scheduler.metadataRequest = nil
            self.accounts.removeValue(forKey: accountId)
        }
    }

    static func refreshMetadata(accountId: String) {
        assert(Thread.isMainThread)
        self.accounts[accountId]?.scheduleMetadata()
    }

    static func updateTimer(accountId: String) {
        assert(Thread.isMainThread)
        self.accounts[accountId]?.updateTimer()
    }

    /// Coalesce visibility changes into one bounded metadata batch. A timer tick never reaches
    /// this path, and neither metadata nor time synchronization can request a release key.
    private func scheduleMetadata() {
        self.metadataNeedsResync = true
        guard !self.metadataScheduled, self.metadataRequest == nil else { return }
        self.metadataScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metadataScheduled = false
            self.metadataNeedsResync = false
            let nodes = self.nodes.values.compactMap { $0.node }
            guard let service = nodes.compactMap({ $0.service }).first, service.hasSession else { return }
            var ids = Set<String>()
            let envelopes = Array(nodes.compactMap { $0.envelope }.filter { ids.insert($0.descriptor.capsuleId).inserted }.prefix(100))
            guard !envelopes.isEmpty else { return }
            self.metadataRequest = service.synchronizeMetadata(envelopes: envelopes) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.metadataRequest = nil
                    if case let .success(changed) = result {
                        for node in self.nodes.values.compactMap({ $0.node }) {
                            if let id = node.envelope?.descriptor.capsuleId, changed.contains(id) {
                                node.requestFullUpdate?(nil)
                            }
                        }
                    }
                    if self.metadataNeedsResync { self.scheduleMetadata() }
                }
            }
        }
    }
}

/// A small, original vector lock. Only its shackle moves at the deadline; the native bubble and
/// date/status node never participate in the seal mask.
private final class CapsuleLockView: UIView {
    private let body = CAShapeLayer()
    private let shackle = CAShapeLayer()
    private var isOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.layer.addSublayer(self.body)
        self.layer.addSublayer(self.shackle)
        for layer in [self.body, self.shackle] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 1.5
            layer.lineCap = .round
            layer.lineJoin = .round
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(size: CGSize, color: UIColor, isOpen: Bool, animated: Bool) {
        let scale = size.width / 14.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let body = UIBezierPath(roundedRect: CGRect(x: 2.0, y: 6.0, width: 10.0, height: 7.0), cornerRadius: 1.7)
        var bodyTransform = transform
        self.body.path = body.cgPath.copy(using: &bodyTransform)
        self.body.strokeColor = color.cgColor
        let path = UIBezierPath()
        path.move(to: CGPoint(x: isOpen ? 10.5 : 4.0, y: 6.0))
        if isOpen {
            path.addLine(to: CGPoint(x: 10.5, y: 3.8))
            path.addCurve(to: CGPoint(x: 5.0, y: 3.2), controlPoint1: CGPoint(x: 10.5, y: -0.2), controlPoint2: CGPoint(x: 5.0, y: -0.2))
            path.addLine(to: CGPoint(x: 5.0, y: 3.2))
        } else {
            path.addLine(to: CGPoint(x: 4.0, y: 3.7))
            path.addCurve(to: CGPoint(x: 10.0, y: 3.7), controlPoint1: CGPoint(x: 4.0, y: -0.3), controlPoint2: CGPoint(x: 10.0, y: -0.3))
            path.addLine(to: CGPoint(x: 10.0, y: 6.0))
        }
        var pathTransform = transform
        let newPath = path.cgPath.copy(using: &pathTransform)
        if animated && self.isOpen != isOpen && !UIAccessibility.isReduceMotionEnabled {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = self.shackle.path
            animation.toValue = newPath
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.shackle.add(animation, forKey: "deadline")
        }
        self.shackle.path = newPath
        self.shackle.strokeColor = color.cgColor
        self.isOpen = isOpen
    }

}

public final class ChatMessageTimeCapsuleBubbleContentNode: ChatMessageBubbleContentNode {
    private var openedNode: ChatMessageTextBubbleContentNode
    private var statusNode: ChatMessageDateAndStatusNode?
    private let label = UILabel()
    private let lock = CapsuleLockView(frame: .zero)
    private let spinner = UIActivityIndicatorView(style: .medium)
    fileprivate var service: CapsuleService?
    fileprivate var envelope: CapsuleEnvelope?
    private var messageContext: CapsuleMessageContext?
    private var identity: String?
    private var generation: UInt64 = 0
    private var release: CapsuleCancellation?
    private var authorization: CapsuleAuthorizationSession?
    private var timeSync: CapsuleCancellation?
    private var pendingPayload: CapsulePayload?
    private var openingRequested = false
    private var opening = false
    private var revealed = false
    fileprivate var opened = false
    private var retryableError = false
    private var subscriptionAccount: String?
    private var observers: [NSObjectProtocol] = []
    private var labelSlot = CGRect.zero
    private var lockFrame = CGRect.zero
    private var contentRect = CGRect.zero
    private var maskLayer: CAGradientLayer?
    private var wasReady = false
    private var backgrounded = false

    override public var visibility: ListViewItemNodeVisibility {
        didSet {
            self.openedNode.visibility = self.visibility
            if oldValue != self.visibility {
                self.updateTickSubscription()
                if case .none = self.visibility {
                    self.cancelTransientPresentation()
                } else if self.revealed && !self.opened {
                    self.requestFullUpdate?(nil)
                }
            }
        }
    }

    required public init(lottieSettings: LottieRenderingSettings) {
        self.openedNode = ChatMessageTextBubbleContentNode(lottieSettings: lottieSettings)
        self.openedNode.presentationOnlyCopySelection = true
        super.init(lottieSettings: lottieSettings)
        self.addSubnode(self.openedNode)
        self.openedNode.isHidden = true
        self.label.textAlignment = .center
        self.label.numberOfLines = 2
        self.label.semanticContentAttribute = .forceLeftToRight
        self.label.isAccessibilityElement = false
        self.spinner.isAccessibilityElement = false
        self.spinner.hidesWhenStopped = true
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override public func didLoad() {
        super.didLoad()
        self.view.addSubview(self.label)
        self.view.addSubview(self.lock)
        self.view.addSubview(self.spinner)
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else { return }
            // Cover text before an app-switcher snapshot. A system authorization browser can
            // temporarily resign activity without entering the background, so do not cancel
            // its completion-proof session until didEnterBackground.
            self.backgrounded = true
            self.openedNode.cancelTextSelection()
            self.openedNode.isHidden = true
            self.label.isHidden = false
            self.lock.isHidden = false
            self.updateTickSubscription()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else { return }
            self.backgrounded = true
            self.cancelTransientPresentation()
            self.openedNode.isHidden = true
            self.label.isHidden = false
            self.lock.isHidden = false
            self.updateTickSubscription()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else { return }
            self.backgrounded = false
            self.requestFullUpdate?(nil)
            self.updateTickSubscription()
        }))
    }

    deinit {
        self.release?.cancel()
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let accountId = self.subscriptionAccount {
            let id = ObjectIdentifier(self)
            // ASDisplayNode can be deallocated off-main. Remove only its identifier on main;
            // opened-only registrations deliberately have no timer that could prune them.
            DispatchQueue.main.async { CapsuleVisibleTickScheduler.remove(id: id, accountId: accountId) }
        }
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let openedLayout = self.openedNode.asyncLayoutContent()
        let statusLayout = ChatMessageDateAndStatusNode.asyncLayout(self.statusNode)
        let pendingPayload = self.pendingPayload
        let openingRequested = self.openingRequested
        let previousIdentity = self.identity

        return { [weak self] item, layoutConstants, preparePosition, selection, constrainedSize, avatarInset in
            let context = timeCapsuleMessageContext(accountPeerId: item.context.account.peerId, message: item.message)
            let service = CapsuleService.configured(accountId: context.accountId)
            let envelope = service.flatMap { try? $0.verify(carrier: item.message.text, context: context) }
            let identity = context.accountId + ":" + String(item.message.id.id) + ":" + (envelope?.descriptor.capsuleId ?? item.message.text)
            let isOpened = envelope.map { service?.isLocallyOpened(capsuleId: $0.descriptor.capsuleId) == true } ?? false
            let payload = envelope.flatMap { service?.cachedPayload(capsuleId: $0.descriptor.capsuleId) }

            // The copy exists only within this content node. Its topMessage and content remain the
            // canonical safe carrier, and it is never passed to enqueue/edit/export/search.
            if let payload = isOpened ? payload : (openingRequested && previousIdentity == identity ? pendingPayload : nil), let envelope {
                let attributes = [TextEntitiesMessageAttribute(entities: self?.nativeEntities(payload.entities) ?? [])]
                let presentationMessage = item.message.withUpdatedText(payload.text).withUpdatedAttributes(attributes)
                let presentationItem = ChatMessageBubbleContentItem(context: item.context, controllerInteraction: item.controllerInteraction, message: presentationMessage, topMessage: item.topMessage, content: item.content, read: item.read, chatLocation: item.chatLocation, presentationData: item.presentationData, associatedData: item.associatedData, attributes: item.attributes, isItemPinned: item.isItemPinned, isItemEdited: false)
                let result = openedLayout(presentationItem, layoutConstants, preparePosition, selection, constrainedSize, avatarInset)
                return (result.0, result.1, result.2, { size, position in
                    let continued = result.3(size, position)
                    return (continued.0, { width in
                        let finalized = continued.1(width)
                        return (finalized.0, { [weak self] animation, synchronousLoads, itemApply in
                            guard let self else { return }
                            self.applyIdentity(item: item, identity: identity, service: service, envelope: envelope, context: context)
                            // The measure pass can finish after logout, deletion or backgrounding.
                            // Revalidate the account cache on main before installing any text layer.
                            let matchesOpeningState = isOpened ? service?.isLocallyOpened(capsuleId: envelope.descriptor.capsuleId) == true : (self.openingRequested && self.pendingPayload == payload)
                            guard !self.backgrounded,
                                  service?.cachedPayload(capsuleId: envelope.descriptor.capsuleId) == payload,
                                  !((service?.isUnavailable(capsuleId: envelope.descriptor.capsuleId)) ?? true),
                                  matchesOpeningState else {
                                self.cancelTransientPresentation()
                                self.openedNode.isHidden = true
                                self.requestFullUpdate?(nil)
                                return
                            }
                            self.openedNode.itemNode = self.itemNode
                            self.openedNode.bubbleBackgroundNode = self.bubbleBackgroundNode
                            self.openedNode.bubbleBackdropNode = self.bubbleBackdropNode
                            self.openedNode.updateIsTextSelectionActive = self.updateIsTextSelectionActive
                            self.openedNode.requestFullUpdate = self.requestFullUpdate
                            self.openedNode.requestInlineUpdate = self.requestInlineUpdate
                            finalized.1(animation, synchronousLoads, itemApply)
                            self.openedNode.frame = CGRect(origin: .zero, size: finalized.0)
                            self.openedNode.visibility = self.visibility
                            self.openedNode.isHidden = self.backgrounded
                            self.opened = isOpened
                            if isOpened {
                                self.statusNode?.isHidden = true
                                self.openedNode.statusNode?.isHidden = false
                                self.label.isHidden = !self.backgrounded
                                self.lock.isHidden = !self.backgrounded
                                self.finishMask()
                            } else if self.openingRequested && !self.opening && !self.backgrounded {
                                if let frame = self.openedNode.statusNode?.frame { self.statusNode?.frame = frame }
                                self.statusNode?.isHidden = false
                                self.openedNode.statusNode?.isHidden = true
                                self.startUnseal(size: finalized.0, envelope: envelope)
                            }
                            self.updateTickSubscription()
                        })
                    })
                })
            }

            let properties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)
            return (properties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] size, position in
                let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
                let colors = incoming ? item.presentationData.theme.theme.chat.message.incoming : item.presentationData.theme.theme.chat.message.outgoing
                let fontSize = item.presentationData.messageFont.pointSize
                let sideInsets = layoutConstants.text.bubbleInsets.left + layoutConstants.text.bubbleInsets.right
                let contentWidth = max(1.0, size.width - sideInsets)
                let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                let strings = item.presentationData.strings
                let longest = envelope.map { CapsuleCountdown.label(remainingSeconds: $0.descriptor.durationSeconds) } ?? strings.TimeCapsule_Unavailable
                let candidates = envelope == nil ? [strings.TimeCapsule_Unavailable] : [longest, strings.TimeCapsule_TapToOpen]
                var labelSize = CGSize.zero
                for candidate in candidates {
                    let measured = (candidate as NSString).boundingRect(with: CGSize(width: contentWidth, height: 1000.0), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).size
                    labelSize.width = max(labelSize.width, ceil(measured.width))
                    labelSize.height = max(labelSize.height, ceil(measured.height))
                }
                let hint = envelope.map { CapsuleBubbleGeometry.estimate(layout: $0.descriptor.layout, fontSize: Double(fontSize), availableWidth: Double(contentWidth)) } ?? (width: 0.0, height: 0.0)
                let iconSize = max(13.0, fontSize * 0.8)
                let gap = max(2.0, fontSize * 0.15)
                let groupHeight = iconSize + gap + labelSize.height
                let hiddenContentSize = CGSize(width: min(contentWidth, max(CGFloat(hint.width), labelSize.width)), height: max(CGFloat(hint.height), groupHeight))
                let topInset = layoutConstants.text.bubbleInsets.top
                let bottomInset = layoutConstants.text.bubbleInsets.bottom
                let dateText = stringForMessageTimestampStatus(context: item.context, message: EngineMessage(item.message), dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: strings, format: item.presentationData.isPreview ? .full : .regular, associatedData: item.associatedData)
                let statusType: ChatMessageDateAndStatusType
                if incoming { statusType = .BubbleIncoming }
                else if item.message.flags.contains(.Failed) { statusType = .BubbleOutgoing(.Failed) }
                else if item.message.flags.isSending && !item.message.isSentOrAcknowledged { statusType = .BubbleOutgoing(.Sending) }
                else { statusType = .BubbleOutgoing(.Sent(read: item.read)) }
                let reactions = mergedMessageReactionsAndPeers(accountPeerId: item.context.account.peerId, accountPeer: item.associatedData.accountPeer, message: item.topMessage)
                let status = statusLayout(ChatMessageDateAndStatusNode.Arguments(context: item.context, presentationData: item.presentationData, edited: false, impressionCount: nil, dateText: dateText, type: statusType, layoutInput: .trailingContent(contentWidth: 10000.0, reactionSettings: .init(displayInline: true, preferAdditionalInset: false)), constrainedSize: CGSize(width: contentWidth, height: size.height), availableReactions: item.associatedData.availableReactions, savedMessageTags: item.associatedData.savedMessageTags, reactions: item.presentationData.isPreview ? [] : reactions.reactions, reactionPeers: reactions.peers, displayAllReactionPeers: true, areReactionsTags: item.topMessage.areReactionsTags(accountPeerId: item.context.account.peerId), areStarReactionsEnabled: item.associatedData.areStarReactionsEnabled, messageEffect: nil, replyCount: 0, starsCount: nil, isPinned: item.isItemPinned, hasAutoremove: item.message.isSelfExpiring, canViewReactionList: canViewMessageReactionList(message: EngineMessage(item.topMessage)), animationCache: item.controllerInteraction.presentationContext.animationCache, animationRenderer: item.controllerInteraction.presentationContext.animationRenderer))

                return (min(size.width, max(hiddenContentSize.width, status.0) + sideInsets), { [weak self] boundingWidth in
                    let finalWidth = max(1.0, boundingWidth - sideInsets)
                    let statusResult = status.1(finalWidth)
                    let finalSize = CGSize(width: boundingWidth, height: topInset + hiddenContentSize.height + statusResult.0.height + bottomInset)
                    let contentRect = CGRect(x: layoutConstants.text.bubbleInsets.left, y: topInset, width: finalWidth, height: hiddenContentSize.height)
                    let lockFrame = CGRect(x: floor(contentRect.midX - iconSize * 0.5), y: floor(contentRect.midY - groupHeight * 0.5), width: iconSize, height: iconSize)
                    let labelFrame = CGRect(x: contentRect.minX, y: lockFrame.maxY + gap, width: finalWidth, height: labelSize.height)
                    return (finalSize, { [weak self] animation, _, _ in
                        guard let self else { return }
                        self.applyIdentity(item: item, identity: identity, service: service, envelope: envelope, context: context, clearOpenedPresentation: true)
                        self.opened = false
                        self.openedNode.isHidden = true
                        self.label.isHidden = false
                        self.lock.isHidden = false
                        self.label.font = font
                        self.label.textColor = colors.primaryTextColor
                        self.labelSlot = labelFrame
                        self.lockFrame = lockFrame
                        self.contentRect = contentRect
                        animation.animator.updateFrame(layer: self.label.layer, frame: labelFrame, completion: nil)
                        animation.animator.updateFrame(layer: self.lock.layer, frame: lockFrame, completion: nil)
                        self.spinner.frame = lockFrame.insetBy(dx: -4.0, dy: -4.0)
                        self.spinner.color = colors.primaryTextColor
                        let statusNode = statusResult.1(self.statusNode == nil ? .None : animation)
                        if self.statusNode !== statusNode {
                            self.statusNode?.removeFromSupernode()
                            self.statusNode = statusNode
                            self.addSubnode(statusNode)
                            statusNode.reactionSelected = { [weak self] _, reaction, sourceView in
                                guard let item = self?.item else { return }
                                item.controllerInteraction.updateMessageReaction(item.topMessage, .reaction(reaction), false, sourceView)
                            }
                            statusNode.openReactionPreview = { [weak self] gesture, sourceNode, reaction in
                                guard let item = self?.item else { gesture?.cancel(); return }
                                item.controllerInteraction.openMessageReactionContextMenu(item.topMessage, sourceNode, gesture, reaction)
                            }
                        }
                        statusNode.isHidden = false
                        statusNode.frame = CGRect(x: contentRect.minX, y: contentRect.maxY, width: statusResult.0.width, height: statusResult.0.height)
                        self.tick(animated: false)
                        self.updateTickSubscription()
                    })
                })
            })
        }
    }

    private func nativeEntities(_ entities: [CapsuleEntity]) -> [MessageTextEntity] {
        return entities.compactMap { entity in
            let type: MessageTextEntityType
            switch entity.type {
            case "bold": type = .Bold
            case "italic": type = .Italic
            case "underline": type = .Underline
            case "strike": type = .Strikethrough
            case "code": type = .Code
            case "pre": type = .Pre(language: entity.language)
            case "spoiler": type = .Spoiler
            case "text_url": guard let url = entity.url else { return nil }; type = .TextUrl(url: url)
            case "url": type = .Url
            default: return nil
            }
            return MessageTextEntity(range: entity.offset ..< (entity.offset + entity.length), type: type)
        }
    }

    private func applyIdentity(item: ChatMessageBubbleContentItem, identity: String, service: CapsuleService?, envelope: CapsuleEnvelope?, context: CapsuleMessageContext, clearOpenedPresentation: Bool = false) {
        let identityChanged = self.identity != identity
        if identityChanged {
            self.cancelTransientPresentation()
            if clearOpenedPresentation {
                self.openedNode.removeFromSupernode()
                self.openedNode = ChatMessageTextBubbleContentNode(lottieSettings: self.lottieSettings)
                self.openedNode.presentationOnlyCopySelection = true
                self.openedNode.isHidden = true
                self.insertSubnode(self.openedNode, at: 0)
            }
            self.pendingPayload = nil
            self.openingRequested = false
            self.retryableError = false
            self.wasReady = false
            self.revealed = false
            self.generation &+= 1
        }
        self.identity = identity
        self.item = item
        self.service = service
        self.envelope = envelope
        self.messageContext = context
        if identityChanged, let subscriptionAccount = self.subscriptionAccount {
            CapsuleVisibleTickScheduler.refreshMetadata(accountId: subscriptionAccount)
        }
    }

    fileprivate func tick(animated: Bool = true) {
        guard let item = self.item, !self.opened else { return }
        let ready: Bool
        if let envelope = self.envelope, let service = self.service, !service.isUnavailable(capsuleId: envelope.descriptor.capsuleId) {
            let remaining = min(envelope.descriptor.durationSeconds, service.remainingSeconds(descriptor: envelope.descriptor))
            ready = remaining <= 0
            self.label.text = self.retryableError ? item.presentationData.strings.TimeCapsule_Retry : (ready ? item.presentationData.strings.TimeCapsule_TapToOpen : CapsuleCountdown.label(remainingSeconds: remaining))
        } else {
            ready = false
            self.label.text = item.presentationData.strings.TimeCapsule_Unavailable
        }
        let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
        let colors = incoming ? item.presentationData.theme.theme.chat.message.incoming : item.presentationData.theme.theme.chat.message.outgoing
        self.lock.update(size: self.lockFrame.size, color: colors.primaryTextColor, isOpen: ready, animated: animated)
        if ready != self.wasReady && animated {
            self.label.layer.animateAlpha(from: 0.0, to: 1.0, duration: UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.14)
        }
        self.wasReady = ready
        self.accessibilityLabel = ready ? item.presentationData.strings.TimeCapsule_TapToOpen : item.presentationData.strings.TimeCapsule_Locked
        self.accessibilityTraits = .button
    }

    private func updateTickSubscription() {
        let accountId: String?
        if case .visible = self.visibility, !self.backgrounded { accountId = self.messageContext?.accountId }
        else { accountId = nil }
        if accountId != self.subscriptionAccount {
            if let previous = self.subscriptionAccount { CapsuleVisibleTickScheduler.remove(self, accountId: previous) }
            self.subscriptionAccount = accountId
            if let accountId {
                CapsuleVisibleTickScheduler.add(self, accountId: accountId)
                self.timeSync = self.service?.synchronizeTime(completion: { [weak self] _ in
                    DispatchQueue.main.async { self?.tick(animated: true) }
                })
            }
        }
        if let accountId { CapsuleVisibleTickScheduler.updateTimer(accountId: accountId) }
    }

    private func activate() {
        guard !self.backgrounded, !self.opened, self.release == nil, self.authorization == nil, !self.opening else { return }
        guard let service = self.service, let envelope = self.envelope, let context = self.messageContext,
              !service.isUnavailable(capsuleId: envelope.descriptor.capsuleId) else {
            if let item = self.item {
                let alert = standardTextAlertController(theme: AlertControllerTheme(presentationTheme: item.presentationData.theme.theme, fontSize: item.presentationData.fontSize), title: item.presentationData.strings.TimeCapsule_Title, text: item.presentationData.strings.TimeCapsule_Unavailable, actions: [TextAlertAction(type: .defaultAction, title: item.presentationData.strings.Common_OK, action: {})])
                item.controllerInteraction.presentController(alert, nil)
            }
            return
        }
        if let cached = service.cachedPayload(capsuleId: envelope.descriptor.capsuleId) {
            self.beginOpening(cached)
            return
        }
        guard service.remainingSeconds(descriptor: envelope.descriptor) <= 0 else {
            if !UIAccessibility.isReduceMotionEnabled {
                self.lock.layer.animatePosition(from: CGPoint(x: -1.5, y: 0.0), to: .zero, duration: 0.16, additive: true)
            } else {
                self.lock.layer.animateAlpha(from: 0.6, to: 1.0, duration: 0.12)
            }
            return
        }
        let generation = self.generation
        let identity = self.identity
        self.retryableError = false
        self.tick(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.generation == generation, self.identity == identity, self.release != nil else { return }
            self.lock.isHidden = true
            self.spinner.startAnimating()
        }
        self.release = service.open(envelope: envelope, context: context, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.identity == identity else { return }
                self.release = nil
                self.spinner.stopAnimating()
                self.lock.isHidden = false
                switch result {
                case let .success(payload):
                    if case .visible = self.visibility, !self.backgrounded { self.beginOpening(payload) }
                case let .failure(error):
                    if let error = error as? CapsuleError, case .notAuthenticated = error {
                        self.authorize(generation: generation, identity: identity)
                        return
                    }
                    self.retryableError = true
                    self.tick(animated: false)
                }
            }
        })
    }

    private func authorize(generation: UInt64, identity: String?) {
        guard let service = self.service, let window = self.view.window else {
            self.retryableError = true
            self.tick(animated: false)
            return
        }
        let authorization = CapsuleAuthorizationSession(service: service, anchor: window, completion: { [weak self] result in
            guard let self, self.generation == generation, self.identity == identity else { return }
            self.authorization = nil
            if case .success = result, case .visible = self.visibility, !self.backgrounded {
                if let accountId = self.messageContext?.accountId {
                    CapsuleVisibleTickScheduler.refreshMetadata(accountId: accountId)
                }
                self.activate()
            } else {
                self.retryableError = true
                self.tick(animated: false)
            }
        })
        self.authorization = authorization
        authorization.start()
    }

    private func beginOpening(_ payload: CapsulePayload) {
        self.pendingPayload = payload
        self.openingRequested = true
        self.requestFullUpdate?(ControlledTransition(duration: UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.52, curve: .easeInOut, interactive: false))
    }

    private func startUnseal(size: CGSize, envelope: CapsuleEnvelope) {
        guard case .visible = self.visibility, !self.backgrounded, let service = self.service else {
            self.openingRequested = false
            self.openedNode.isHidden = true
            return
        }
        self.opening = true
        let generation = self.generation
        let identity = self.identity
        let reduced = UIAccessibility.isReduceMotionEnabled
        let duration = reduced ? 0.1 : 0.52
        // Cover only content: date/checks/reactions belong to the native status node and stay crisp.
        let mask = CAGradientLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.startPoint = CGPoint(x: 0.0, y: 0.5)
        mask.endPoint = CGPoint(x: 1.0, y: 0.5)
        mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        let closedLocations: [NSNumber] = reduced ? [0.0, 0.0, 1.0, 1.0] : [0.49, 0.5, 0.5, 0.51]
        let openLocations: [NSNumber] = [0.0, 0.0, 1.0, 1.0]
        mask.locations = closedLocations
        mask.opacity = 0.0
        self.maskLayer = mask
        self.openedNode.layer.mask = mask
        self.openedNode.isHidden = false
        self.openedNode.isUserInteractionEnabled = false
        self.label.layer.animateAlpha(from: 1.0, to: 0.0, duration: reduced ? 0.08 : 0.1, removeOnCompletion: false)
        self.lock.layer.animateAlpha(from: 1.0, to: 0.0, duration: reduced ? 0.08 : 0.22, removeOnCompletion: false)
        if !reduced {
            self.lock.layer.animatePosition(from: .zero, to: CGPoint(x: 0.0, y: -2.0), duration: 0.1, additive: true)
            self.lock.layer.animateScale(from: 1.0, to: 1.04, duration: 0.1)
        }
        let revealDelay = reduced ? 0.0 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) { [weak self, weak mask] in
            guard let self, let mask, self.generation == generation, self.identity == identity, self.opening, !self.backgrounded else { return }
            do {
                // Persist BEFORE the first visible glyph. A cancelled/lost completion can never
                // resurrect a not-yet-opened state after the user has already seen plaintext.
                try service.markLocallyOpened(envelope: envelope)
                self.revealed = true
            } catch {
                self.cancelTransientPresentation()
                self.retryableError = true
                self.requestFullUpdate?(nil)
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.locations = openLocations
            mask.opacity = 1.0
            CATransaction.commit()
            let animation = CABasicAnimation(keyPath: reduced ? "opacity" : "locations")
            animation.fromValue = reduced ? NSNumber(value: 0.0) : closedLocations
            animation.toValue = reduced ? NSNumber(value: 1.0) : openLocations
            animation.duration = reduced ? 0.1 : 0.30
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            mask.add(animation, forKey: "unseal")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == generation, self.identity == identity, self.opening else { return }
            self.opened = self.revealed
            self.openingRequested = false
            self.pendingPayload = nil
            self.opening = false
            self.label.isHidden = self.opened
            self.lock.isHidden = self.opened
            self.finishMask()
            self.statusNode?.isHidden = self.opened
            self.openedNode.statusNode?.isHidden = !self.opened
            self.updateTickSubscription()
            self.requestFullUpdate?(nil)
        }
    }

    private func finishMask() {
        self.maskLayer?.removeAllAnimations()
        self.maskLayer = nil
        self.openedNode.layer.mask = nil
        self.openedNode.isUserInteractionEnabled = true
        self.label.layer.removeAllAnimations()
        self.lock.layer.removeAllAnimations()
    }

    private func cancelTransientPresentation() {
        self.generation &+= 1
        self.release?.cancel()
        self.release = nil
        self.authorization?.cancel()
        self.authorization = nil
        self.timeSync?.cancel()
        self.timeSync = nil
        self.spinner.stopAnimating()
        self.finishMask()
        self.openingRequested = false
        self.opening = false
        self.pendingPayload = nil
        if !self.revealed {
            self.openedNode.isHidden = true
            self.label.isHidden = false
            self.lock.isHidden = false
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if self.opened { return self.openedNode.tapActionAtPoint(point, gesture: gesture, isEstimating: isEstimating) }
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak self] in self?.activate() }), hasLongTapAction: false)
    }

    override public func accessibilityActivate() -> Bool {
        if self.opened { return self.openedNode.accessibilityActivate() }
        self.activate()
        return true
    }

    override public func updateTouchesAtPoint(_ point: CGPoint?) { if self.opened { self.openedNode.updateTouchesAtPoint(point) } }
    override public func updateSearchTextHighlightState(text: String?, messages: [EngineMessage.Index]?) { if self.opened { self.openedNode.updateSearchTextHighlightState(text: text, messages: messages) } }
    override public func updateIsExtractedToContextPreview(_ value: Bool) { if self.opened { self.openedNode.updateIsExtractedToContextPreview(value) } }
    override public func willUpdateIsExtractedToContextPreview(_ value: Bool) { if self.opened { self.openedNode.willUpdateIsExtractedToContextPreview(value) } }
    override public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) { if self.opened { self.openedNode.updateAbsoluteRect(rect, within: containerSize) } }
    override public func reactionTargetView(value: MessageReaction.Reaction) -> UIView? { return self.opened ? self.openedNode.reactionTargetView(value: value) : self.statusNode?.reactionView(value: value) }
    override public func getStatusNode() -> ASDisplayNode? { return self.opened ? self.openedNode.getStatusNode() : self.statusNode }
}
