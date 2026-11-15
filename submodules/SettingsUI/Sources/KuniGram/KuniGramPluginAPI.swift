import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import Display
import PresentationDataUtils
import UndoUI

public final class KuniGramPluginAPI {
    private let pluginId: String
    private weak var context: AccountContext?
    private let logHandler: (String) -> Void
    private var webSockets: [String: URLSessionWebSocketTask] = [:]
    private let storageURL: URL
    private let mediaDirURL: URL

    public init(pluginId: String, context: AccountContext?, logHandler: @escaping (String) -> Void) {
        self.pluginId = pluginId
        self.context = context
        self.logHandler = logHandler

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let base = docs.appendingPathComponent("KuniGram", isDirectory: true)
        let storageDir = base.appendingPathComponent("Storage", isDirectory: true)
        let mediaDir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let safeId = pluginId.replacingOccurrences(of: "/", with: "_")
        self.storageURL = storageDir.appendingPathComponent("\(safeId).json")
        self.mediaDirURL = mediaDir
    }

    public func buildAPIObject() -> KuniPyValue {
        return .object([
            "tg": self.buildTelegramModule(),
            "net": self.buildNetworkModule(),
            "camera": self.buildCameraModule(),
            "media": self.buildMediaModule(),
            "ui": self.buildUIModule(),
            "storage": self.buildStorageModule(),
            "log": .nativeFunction { [weak self] args, _ in
                let msg = args.map { $0.stringValue }.joined(separator: " ")
                self?.logHandler(msg)
                return .none
            }
        ])
    }

    // MARK: - Telegram API (`api.tg`)

    public func buildTelegramModule() -> KuniPyValue {
        return .object([
            "get_me": .nativeFunction { [weak self] _, _ in
                guard let self = self, let context = self.context else { return .none }
                let semaphore = DispatchSemaphore(value: 0)
                var result: KuniPyValue = .none
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                |> take(1)).startStandalone(next: { peer in
                    if let peer = peer {
                        result = Self.peerToPyDict(peer)
                    }
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 5.0)
                return result
            },
            "get_user": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .none }
                let rawId = kwargs["peer_id"]?.intValue ?? args.first?.intValue ?? 0
                let peerId = PeerId(rawId)
                let semaphore = DispatchSemaphore(value: 0)
                var result: KuniPyValue = .none
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> take(1)).startStandalone(next: { peer in
                    if let peer = peer {
                        result = Self.peerToPyDict(peer)
                    }
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 5.0)
                return result
            },
            "send_message": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                let peerRaw = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil)
                let text = kwargs["text"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                guard let rawId = peerRaw, !text.isEmpty else { return .bool(false) }

                let peerId = PeerId(rawId)
                var replySubject: EngineMessageReplySubject? = nil
                if let replyMsgId = kwargs["reply_to"]?.intValue ?? (args.count > 2 ? args[2].intValue : nil) {
                    let msgId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(replyMsgId))
                    replySubject = EngineMessageReplySubject(messageId: msgId, quote: nil, innerSubject: nil)
                }

                let message = EnqueueMessage.message(
                    text: text,
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: nil,
                    threadId: nil,
                    replyToMessageId: replySubject,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )
                let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [message]).startStandalone()
                self.logHandler("tg.send_message -> peer \(rawId)")
                return .bool(true)
            },
            "edit_message": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let rawMsgId = kwargs["message_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) else {
                    return .bool(false)
                }
                let text = kwargs["text"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "")
                let msgId = MessageId(peerId: PeerId(rawPeer), namespace: Namespaces.Message.Cloud, id: Int32(rawMsgId))
                let _ = context.engine.messages.editMessage(messageId: msgId, text: text, media: .keep, entities: nil, webpagePreviewAttribute: nil, invertMediaAttribute: nil).startStandalone()
                self.logHandler("tg.edit_message -> \(rawMsgId)")
                return .bool(true)
            },
            "delete_messages": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil) else {
                    return .bool(false)
                }
                let peerId = PeerId(rawPeer)
                var ids: [MessageId] = []
                if case let .list(arr)? = kwargs["message_ids"] ?? (args.count > 1 ? args[1] : nil) {
                    for item in arr {
                        if let mid = item.intValue {
                            ids.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(mid)))
                        }
                    }
                } else if let singleId = kwargs["message_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) {
                    ids.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(singleId)))
                }
                guard !ids.isEmpty else { return .bool(false) }
                let forEveryone = (kwargs["for_everyone"] ?? (args.count > 2 ? args[2] : .bool(true))).isTruthy
                let _ = context.engine.messages.deleteMessagesInteractively(messageIds: ids, type: forEveryone ? .forEveryone : .forLocalPeer).startStandalone()
                self.logHandler("tg.delete_messages -> count \(ids.count)")
                return .bool(true)
            },
            "forward_messages": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let fromPeerRaw = kwargs["from_peer"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let toPeerRaw = kwargs["to_peer"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) else {
                    return .bool(false)
                }
                let fromPeerId = PeerId(fromPeerRaw)
                let toPeerId = PeerId(toPeerRaw)
                var forwardMsgs: [EnqueueMessage] = []
                if case let .list(arr)? = kwargs["message_ids"] ?? (args.count > 2 ? args[2] : nil) {
                    for item in arr {
                        if let mid = item.intValue {
                            let msgId = MessageId(peerId: fromPeerId, namespace: Namespaces.Message.Cloud, id: Int32(mid))
                            forwardMsgs.append(.forward(source: msgId, threadId: nil, grouping: .auto, attributes: [], correlationId: nil))
                        }
                    }
                }
                guard !forwardMsgs.isEmpty else { return .bool(false) }
                let _ = enqueueMessages(account: context.account, peerId: toPeerId, messages: forwardMsgs).startStandalone()
                self.logHandler("tg.forward_messages -> \(forwardMsgs.count) msgs")
                return .bool(true)
            },
            "send_photo": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil) else {
                    return .bool(false)
                }
                let path = kwargs["path"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                let caption = kwargs["caption"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "")
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let image = UIImage(data: data),
                      let jpegData = image.jpegData(compressionQuality: 0.87) else {
                    return .bool(false)
                }
                let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max))
                context.account.postbox.mediaBox.storeResourceData(resource.id, data: jpegData)
                let representation = TelegramMediaImageRepresentation(
                    dimensions: PixelDimensions(width: Int32(image.size.width * image.scale), height: Int32(image.size.height * image.scale)),
                    resource: resource,
                    progressiveSizes: [],
                    immediateThumbnailData: nil,
                    hasVideo: false,
                    isPersonal: false
                )
                let media = TelegramMediaImage(
                    imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min...Int64.max)),
                    representations: [representation],
                    immediateThumbnailData: nil,
                    reference: nil,
                    partialReference: nil,
                    flags: []
                )
                let msg = EnqueueMessage.message(
                    text: caption,
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: .standalone(media: media),
                    threadId: nil,
                    replyToMessageId: nil,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )
                let _ = enqueueMessages(account: context.account, peerId: PeerId(rawPeer), messages: [msg]).startStandalone()
                self.logHandler("tg.send_photo -> peer \(rawPeer)")
                return .bool(true)
            },
            "send_file": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil) else {
                    return .bool(false)
                }
                let path = kwargs["path"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                let caption = kwargs["caption"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "")
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url) else {
                    return .bool(false)
                }
                let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max))
                context.account.postbox.mediaBox.storeResourceData(resource.id, data: data)
                let file = TelegramMediaFile(
                    fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min...Int64.max)),
                    partialReference: nil,
                    resource: resource,
                    previewRepresentations: [],
                    videoThumbnails: [],
                    immediateThumbnailData: nil,
                    mimeType: "application/octet-stream",
                    size: Int64(data.count),
                    attributes: [.FileName(fileName: url.lastPathComponent)],
                    alternativeRepresentations: []
                )
                let msg = EnqueueMessage.message(
                    text: caption,
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: .standalone(media: file),
                    threadId: nil,
                    replyToMessageId: nil,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )
                let _ = enqueueMessages(account: context.account, peerId: PeerId(rawPeer), messages: [msg]).startStandalone()
                self.logHandler("tg.send_file -> \(url.lastPathComponent)")
                return .bool(true)
            },
            "send_reaction": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let rawMsgId = kwargs["message_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) else {
                    return .bool(false)
                }
                let emoji = kwargs["emoji"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "❤️")
                let msgId = MessageId(peerId: PeerId(rawPeer), namespace: Namespaces.Message.Cloud, id: Int32(rawMsgId))
                let _ = context.engine.messages.updateMessageReactionsInteractively(
                    messageIds: [msgId],
                    reactions: [.reaction(value: .builtin(emoji), isSelected: true)],
                    isLarge: false,
                    storeAsRecentlyUsed: false
                ).startStandalone()
                self.logHandler("tg.send_reaction -> \(emoji)")
                return .bool(true)
            },
            "set_typing": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil) else {
                    return .bool(false)
                }
                context.account.pendingMessageManager.updatePendingMessageAction(
                    peerId: PeerId(rawPeer),
                    threadId: nil,
                    action: .text
                )
                return .bool(true)
            },
            "get_chats": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .list([]) }
                let limit = Int(kwargs["limit"]?.intValue ?? args.first?.intValue ?? 30)
                let semaphore = DispatchSemaphore(value: 0)
                var result: [KuniPyValue] = []
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.ChatList(count: limit))
                |> take(1)).startStandalone(next: { list in
                    for item in list.items {
                        result.append(Self.peerToPyDict(item.renderedPeer.peer))
                    }
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 5.0)
                return .list(result)
            },
            "get_star_gifts": .nativeFunction { [weak self] _, _ in
                guard let self = self, let context = self.context else { return .list([]) }
                let _ = context.engine.payments.keepStarGiftsUpdated().startStandalone()
                let semaphore = DispatchSemaphore(value: 0)
                var result: [KuniPyValue] = []
                let _ = (context.engine.payments.cachedStarGifts()
                |> take(1)).startStandalone(next: { gifts in
                    if let gifts = gifts {
                        for gift in gifts {
                            switch gift {
                            case let .generic(g):
                                result.append(.dict([
                                    "id": .int(g.id),
                                    "price": .int(g.price),
                                    "convert_stars": .int(g.convertStars),
                                    "is_limited": .bool(g.availability != nil),
                                    "remains": .int(Int64(g.availability?.remains ?? -1)),
                                    "total": .int(Int64(g.availability?.total ?? -1))
                                ]))
                            case let .unique(u):
                                result.append(.dict([
                                    "id": .int(u.id),
                                    "slug": .string(u.slug),
                                    "title": .string(u.title),
                                    "number": .int(Int64(u.number)),
                                    "is_unique": .bool(true)
                                ]))
                            }
                        }
                    }
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 5.0)
                return .list(result)
            },
            "send_star_gift": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .dict(["ok": .bool(false), "error": .string("No context")]) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let giftId = kwargs["gift_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) else {
                    return .dict(["ok": .bool(false), "error": .string("peer_id and gift_id required")])
                }
                let text = kwargs["text"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "")
                let hideName = (kwargs["hide_name"] ?? (args.count > 3 ? args[3] : .bool(false))).isTruthy
                let includeUpgrade = (kwargs["upgrade"] ?? .bool(false)).isTruthy
                let source = BotPaymentInvoiceSource.starGift(
                    hideName: hideName,
                    includeUpgrade: includeUpgrade,
                    peerId: PeerId(rawPeer),
                    giftId: giftId,
                    text: text.isEmpty ? nil : text,
                    entities: nil
                )
                let semaphore = DispatchSemaphore(value: 0)
                var out: [String: KuniPyValue] = ["ok": .bool(false)]
                let _ = (context.engine.payments.fetchBotPaymentForm(source: source, themeParams: nil)
                |> mapToSignal { form -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
                    return context.engine.payments.sendStarsPaymentForm(formId: form.id, source: source)
                }
                |> take(1)).startStandalone(next: { _ in
                    out = ["ok": .bool(true), "gift_id": .int(giftId), "peer_id": .int(rawPeer)]
                    semaphore.signal()
                }, error: { err in
                    out = ["ok": .bool(false), "error": .string(String(describing: err))]
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 15.0)
                self.logHandler("tg.send_star_gift -> gift \(giftId) to \(rawPeer)")
                return .dict(out)
            },
            "buy_star_gift": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .dict(["ok": .bool(false)]) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil) else {
                    return .dict(["ok": .bool(false), "error": .string("peer_id required")])
                }
                let slug = kwargs["slug"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                let text = kwargs["text"]?.stringValue ?? (args.count > 2 ? args[2].stringValue : "")
                let hideName = (kwargs["hide_name"] ?? .bool(true)).isTruthy
                let semaphore = DispatchSemaphore(value: 0)
                var out: [String: KuniPyValue] = ["ok": .bool(false)]
                let _ = (context.engine.payments.buyStarGift(
                    slug: slug,
                    peerId: PeerId(rawPeer),
                    price: nil,
                    hideName: hideName,
                    text: text.isEmpty ? nil : text,
                    entities: nil
                ) |> take(1)).startStandalone(error: { err in
                    out = ["ok": .bool(false), "error": .string(String(describing: err))]
                    semaphore.signal()
                }, completed: {
                    out = ["ok": .bool(true), "slug": .string(slug), "peer_id": .int(rawPeer)]
                    semaphore.signal()
                })
                _ = semaphore.wait(timeout: .now() + 15.0)
                self.logHandler("tg.buy_star_gift -> \(slug) to \(rawPeer)")
                return .dict(out)
            },
            "transfer_star_gift": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawFromPeer = kwargs["from_peer"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let msgId = kwargs["message_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil),
                      let rawToPeer = kwargs["to_peer"]?.intValue ?? (args.count > 2 ? args[2].intValue : nil) else {
                    return .bool(false)
                }
                let reference = StarGiftReference.message(messageId: MessageId(peerId: PeerId(rawFromPeer), namespace: Namespaces.Message.Cloud, id: Int32(msgId)))
                let _ = context.engine.payments.transferStarGift(prepaid: false, reference: reference, peerId: PeerId(rawToPeer)).startStandalone()
                self.logHandler("tg.transfer_star_gift -> \(msgId) to \(rawToPeer)")
                return .bool(true)
            },
            "convert_star_gift": .nativeFunction { [weak self] args, kwargs in
                guard let self = self, let context = self.context else { return .bool(false) }
                guard let rawPeer = kwargs["peer_id"]?.intValue ?? (args.count > 0 ? args[0].intValue : nil),
                      let msgId = kwargs["message_id"]?.intValue ?? (args.count > 1 ? args[1].intValue : nil) else {
                    return .bool(false)
                }
                let reference = StarGiftReference.message(messageId: MessageId(peerId: PeerId(rawPeer), namespace: Namespaces.Message.Cloud, id: Int32(msgId)))
                let _ = context.engine.payments.convertStarGift(reference: reference).startStandalone()
                self.logHandler("tg.convert_star_gift -> \(msgId)")
                return .bool(true)
            }
        ])
    }

    private static func peerToPyDict(_ peer: EnginePeer) -> KuniPyValue {
        return .dict([
            "id": .int(peer.id.toInt64()),
            "title": .string(peer.displayTitle(strings: PresentationStrings.defaultStrings, displayOrder: .firstLast)),
            "username": .string(peer.addressName ?? ""),
            "is_bot": .bool({
                if case let .user(u) = peer { return u.botInfo != nil }
                return false
            }())
        ])
    }

    // MARK: - Network API (`api.net` / `requests`)

    public func buildNetworkModule() -> KuniPyValue {
        return .object([
            "get": .nativeFunction { [weak self] args, kwargs in
                let url = kwargs["url"]?.stringValue ?? args.first?.stringValue ?? ""
                return self?.performHTTP(method: "GET", urlString: url, kwargs: kwargs) ?? .none
            },
            "post": .nativeFunction { [weak self] args, kwargs in
                let url = kwargs["url"]?.stringValue ?? args.first?.stringValue ?? ""
                return self?.performHTTP(method: "POST", urlString: url, kwargs: kwargs) ?? .none
            },
            "put": .nativeFunction { [weak self] args, kwargs in
                let url = kwargs["url"]?.stringValue ?? args.first?.stringValue ?? ""
                return self?.performHTTP(method: "PUT", urlString: url, kwargs: kwargs) ?? .none
            },
            "delete": .nativeFunction { [weak self] args, kwargs in
                let url = kwargs["url"]?.stringValue ?? args.first?.stringValue ?? ""
                return self?.performHTTP(method: "DELETE", urlString: url, kwargs: kwargs) ?? .none
            },
            "request": .nativeFunction { [weak self] args, kwargs in
                let method = kwargs["method"]?.stringValue ?? (args.count > 0 ? args[0].stringValue : "GET")
                let url = kwargs["url"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                return self?.performHTTP(method: method, urlString: url, kwargs: kwargs) ?? .none
            },
            "ws_connect": .nativeFunction { [weak self] args, kwargs in
                guard let self = self else { return .none }
                let urlStr = kwargs["url"]?.stringValue ?? args.first?.stringValue ?? ""
                guard let url = URL(string: urlStr) else { return .none }
                let wsId = UUID().uuidString
                let task = URLSession.shared.webSocketTask(with: url)
                self.webSockets[wsId] = task
                task.resume()
                self.logHandler("ws_connect -> \(urlStr)")
                return .string(wsId)
            },
            "ws_send": .nativeFunction { [weak self] args, kwargs in
                guard let self = self else { return .bool(false) }
                let wsId = kwargs["ws_id"]?.stringValue ?? (args.count > 0 ? args[0].stringValue : "")
                let msg = kwargs["text"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                guard let task = self.webSockets[wsId] else { return .bool(false) }
                task.send(.string(msg)) { _ in }
                return .bool(true)
            },
            "ws_close": .nativeFunction { [weak self] args, _ in
                guard let self = self, let wsId = args.first?.stringValue else { return .bool(false) }
                self.webSockets[wsId]?.cancel(with: .normalClosure, reason: nil)
                self.webSockets.removeValue(forKey: wsId)
                return .bool(true)
            }
        ])
    }

    private func performHTTP(method: String, urlString: String, kwargs: [String: KuniPyValue]) -> KuniPyValue {
        guard var components = URLComponents(string: urlString) else {
            return .dict(["status": .int(0), "error": .string("Invalid URL")])
        }
        if case let .dict(params)? = kwargs["params"] {
            var items = components.queryItems ?? []
            for (k, v) in params {
                items.append(URLQueryItem(name: k, value: v.stringValue))
            }
            components.queryItems = items
        }
        guard let url = components.url else {
            return .dict(["status": .int(0), "error": .string("Invalid URL")])
        }

        let timeout = kwargs["timeout"]?.doubleValue ?? 20.0
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.uppercased()

        if case let .dict(headers)? = kwargs["headers"] {
            for (k, v) in headers {
                request.setValue(v.stringValue, forHTTPHeaderField: k)
            }
        }

        if let jsonVal = kwargs["json"] {
            let obj = jsonVal.toJSONObject()
            if JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj, options: []) {
                request.httpBody = data
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        } else if let dataVal = kwargs["data"] ?? kwargs["body"] {
            request.httpBody = dataVal.stringValue.data(using: .utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseDict: [String: KuniPyValue] = ["status": .int(0), "text": .string(""), "json": .none]

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                responseDict["error"] = .string(error.localizedDescription)
            }
            if let http = response as? HTTPURLResponse {
                responseDict["status"] = .int(Int64(http.statusCode))
                var respHeaders: [String: KuniPyValue] = [:]
                for (k, v) in http.allHeaderFields {
                    respHeaders[String(describing: k)] = .string(String(describing: v))
                }
                responseDict["headers"] = .dict(respHeaders)
            }
            if let data = data {
                let text = String(data: data, encoding: .utf8) ?? ""
                responseDict["text"] = .string(text)
                if let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    responseDict["json"] = KuniPyValue.fromJSONObject(jsonObj)
                }
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 2.0)
        return .dict(responseDict)
    }

    // MARK: - Camera & Media API (`api.camera` / `api.media`)

    public func buildCameraModule() -> KuniPyValue {
        return .object([
            "take_photo": .nativeFunction { [weak self] args, kwargs in
                guard let self = self else { return .none }
                let positionStr = kwargs["camera"]?.stringValue ?? args.first?.stringValue ?? "back"
                let position: AVCaptureDevice.Position = positionStr.lowercased() == "front" ? .front : .back
                return self.capturePhotoSync(position: position)
            }
        ])
    }

    public func buildMediaModule() -> KuniPyValue {
        return .object([
            "save_to_gallery": .nativeFunction { args, _ in
                guard let path = args.first?.stringValue,
                      let image = UIImage(contentsOfFile: path) else {
                    return .bool(false)
                }
                DispatchQueue.main.async {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
                return .bool(true)
            },
            "resize_image": .nativeFunction { [weak self] args, kwargs in
                guard let self = self else { return .none }
                let path = kwargs["path"]?.stringValue ?? (args.count > 0 ? args[0].stringValue : "")
                let width = CGFloat(kwargs["width"]?.doubleValue ?? (args.count > 1 ? args[1].doubleValue ?? 512 : 512))
                let height = CGFloat(kwargs["height"]?.doubleValue ?? (args.count > 2 ? args[2].doubleValue ?? 512 : 512))
                guard let image = UIImage(contentsOfFile: path) else { return .none }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
                let resized = renderer.image { _ in
                    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                let outURL = self.mediaDirURL.appendingPathComponent("resized_\(UUID().uuidString).jpg")
                if let data = resized.jpegData(compressionQuality: 0.85) {
                    try? data.write(to: outURL)
                    return .string(outURL.path)
                }
                return .none
            }
        ])
    }

    private func capturePhotoSync(position: AVCaptureDevice.Position) -> KuniPyValue {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            return .dict(["error": .string("Camera permission denied")])
        }
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return .dict(["error": .string("Camera unavailable")])
        }
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            return .dict(["error": .string("Camera output unavailable")])
        }
        session.addInput(input)
        session.addOutput(output)

        let delegate = KuniGramPhotoCaptureDelegate(saveURL: self.mediaDirURL.appendingPathComponent("photo_\(UUID().uuidString).jpg"))
        session.startRunning()
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: delegate)
        _ = delegate.semaphore.wait(timeout: .now() + 8.0)
        session.stopRunning()

        if let path = delegate.savedPath {
            self.logHandler("camera.take_photo -> \(path)")
            return .dict([
                "path": .string(path),
                "width": .int(Int64(delegate.width)),
                "height": .int(Int64(delegate.height)),
                "base64": .string(delegate.base64 ?? "")
            ])
        }
        return .dict(["error": .string(delegate.errorText ?? "Capture failed")])
    }

    // MARK: - UI API (`api.ui`)

    public func buildUIModule() -> KuniPyValue {
        return .object([
            "show_toast": .nativeFunction { [weak self] args, _ in
                let text = args.map { $0.stringValue }.joined(separator: " ")
                guard let context = self?.context else { return .bool(false) }
                DispatchQueue.main.async {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let controller = UndoOverlayController(
                        presentationData: presentationData,
                        content: .info(title: nil, text: text, timeout: 3.0, customUndoText: nil),
                        elevatedLayout: false,
                        action: { _ in return false }
                    )
                    context.sharedContext.mainWindow?.present(controller, on: .root)
                }
                return .bool(true)
            },
            "show_alert": .nativeFunction { [weak self] args, kwargs in
                let title = kwargs["title"]?.stringValue ?? (args.count > 0 ? args[0].stringValue : "KuniGram")
                let text = kwargs["message"]?.stringValue ?? (args.count > 1 ? args[1].stringValue : "")
                guard let context = self?.context else { return .bool(false) }
                DispatchQueue.main.async {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let alert = textAlertController(
                        context: context,
                        title: title,
                        text: text,
                        actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                    )
                    context.sharedContext.mainWindow?.present(alert, on: .root)
                }
                return .bool(true)
            }
        ])
    }

    // MARK: - Persistent Storage API (`api.storage`)

    public func buildStorageModule() -> KuniPyValue {
        return .object([
            "get": .nativeFunction { [weak self] args, _ in
                guard let self = self, let key = args.first?.stringValue else { return .none }
                let dict = self.loadStorage()
                if let val = dict[key] {
                    return KuniPyValue.fromJSONObject(val)
                }
                return args.count > 1 ? args[1] : .none
            },
            "set": .nativeFunction { [weak self] args, _ in
                guard let self = self, args.count >= 2 else { return .bool(false) }
                let key = args[0].stringValue
                var dict = self.loadStorage()
                dict[key] = args[1].toJSONObject()
                self.saveStorage(dict)
                return .bool(true)
            },
            "delete": .nativeFunction { [weak self] args, _ in
                guard let self = self, let key = args.first?.stringValue else { return .bool(false) }
                var dict = self.loadStorage()
                dict.removeValue(forKey: key)
                self.saveStorage(dict)
                return .bool(true)
            },
            "keys": .nativeFunction { [weak self] _, _ in
                guard let self = self else { return .list([]) }
                return .list(self.loadStorage().keys.map { .string($0) })
            }
        ])
    }

    private func loadStorage() -> [String: Any] {
        guard let data = try? Data(contentsOf: self.storageURL),
              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func saveStorage(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: self.storageURL)
        }
    }
}

private final class KuniGramPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    let saveURL: URL
    var savedPath: String?
    var width: Int = 0
    var height: Int = 0
    var base64: String?
    var errorText: String?

    init(saveURL: URL) {
        self.saveURL = saveURL
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { self.semaphore.signal() }
        if let error = error {
            self.errorText = error.localizedDescription
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            self.errorText = "Empty photo data"
            return
        }
        try? data.write(to: self.saveURL)
        self.savedPath = self.saveURL.path
        self.width = Int(image.size.width * image.scale)
        self.height = Int(image.size.height * image.scale)
        self.base64 = data.base64EncodedString()
    }
}
