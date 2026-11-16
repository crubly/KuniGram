import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

public struct KuniGramLocalGift: Codable, Equatable {
    public let id: String
    public var slug: String
    public var title: String
    public var number: Int32
    public var modelName: String
    public var backdropName: String
    public var symbolName: String
    public var isCrafted: Bool
    public var inProfile: Bool
    public var inGramWallet: Bool
    public var sentToPeerTitle: String?
    public var createdAt: TimeInterval

    public init(
        id: String = UUID().uuidString,
        slug: String,
        title: String,
        number: Int32,
        modelName: String,
        backdropName: String,
        symbolName: String,
        isCrafted: Bool = false,
        inProfile: Bool = true,
        inGramWallet: Bool = false,
        sentToPeerTitle: String? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.number = number
        self.modelName = modelName
        self.backdropName = backdropName
        self.symbolName = symbolName
        self.isCrafted = isCrafted
        self.inProfile = inProfile
        self.inGramWallet = inGramWallet
        self.sentToPeerTitle = sentToPeerTitle
        self.createdAt = createdAt
    }
}

public struct KuniGramWalletNFT: Codable, Equatable {
    public let id: String
    public var name: String
    public var address: String
    public var sourceUrl: String
    public var collectionName: String
}

public final class KuniGramLocalGiftStore {
    public static let shared = KuniGramLocalGiftStore()
    public static let didChangeNotification = Notification.Name("KuniGramLocalGiftStoreDidChange")

    private let giftsFileURL: URL
    private let walletNFTsFileURL: URL
    private let walletEnabledKey = "kunigram_gram_wallet_enabled"
    private let walletBalanceKey = "kunigram_gram_wallet_balance_ton"
    private let walletActiveGiftIdKey = "kunigram_gram_wallet_active_gift_id"

    public private(set) var gifts: [KuniGramLocalGift] = []
    public private(set) var walletNFTs: [KuniGramWalletNFT] = []

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("KuniGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.giftsFileURL = dir.appendingPathComponent("local_gifts.json")
        self.walletNFTsFileURL = dir.appendingPathComponent("wallet_nfts.json")
        self.load()
        NotificationCenter.default.addObserver(
            forName: KuniGramLocalProfileGifts.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let activeSlugs = Set(KuniGramLocalProfileGifts.shared.gifts.compactMap { item -> String? in
                if case let .unique(u) = item.gift { return u.slug.lowercased() }
                return nil
            })
            let before = self.gifts.count
            self.gifts.removeAll { gift in
                !gift.isCrafted && !activeSlugs.contains(gift.slug.lowercased())
            }
            if self.gifts.count != before {
                self.save()
            }
        }
    }

    public var isGramWalletEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.walletEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: self.walletEnabledKey)
            self.notify()
        }
    }

    public var gramWalletBalanceTON: Double {
        get {
            if UserDefaults.standard.object(forKey: self.walletBalanceKey) == nil {
                return 0.0
            }
            return UserDefaults.standard.double(forKey: self.walletBalanceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.walletBalanceKey)
            self.notify()
        }
    }

    public var activeWalletCustomizationGiftId: String? {
        get { UserDefaults.standard.string(forKey: self.walletActiveGiftIdKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: self.walletActiveGiftIdKey)
            self.notify()
        }
    }

    public var activeWalletCustomizationGift: KuniGramLocalGift? {
        guard let id = self.activeWalletCustomizationGiftId else { return nil }
        return self.gifts.first(where: { $0.id == id && $0.inGramWallet })
    }

    private func load() {
        if let data = try? Data(contentsOf: self.giftsFileURL),
           let decoded = try? JSONDecoder().decode([KuniGramLocalGift].self, from: data) {
            self.gifts = decoded
        }
        if let data = try? Data(contentsOf: self.walletNFTsFileURL),
           let decoded = try? JSONDecoder().decode([KuniGramWalletNFT].self, from: data) {
            self.walletNFTs = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self.gifts) {
            try? data.write(to: self.giftsFileURL)
        }
        if let data = try? JSONEncoder().encode(self.walletNFTs) {
            try? data.write(to: self.walletNFTsFileURL)
        }
        self.notify()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    public func addGiftBySlug(_ rawSlug: String, context: AccountContext, completion: @escaping (KuniGramLocalGift) -> Void) {
        let cleanSlug = rawSlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://t.me/nft/", with: "")
            .replacingOccurrences(of: "t.me/nft/", with: "")

        let parsed = Self.parseSlugFallback(cleanSlug)
        let _ = (context.engine.payments.getUniqueStarGift(slug: cleanSlug)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] unique in
            guard let self = self else { return }
            var modelName = "Original"
            var backdropName = "Classic"
            var symbolName = "Star"
            for attr in unique.attributes {
                switch attr {
                case let .model(name, _, _, _):
                    modelName = name
                case let .backdrop(name, _, _, _, _, _, _):
                    backdropName = name
                case let .pattern(name, _, _):
                    symbolName = name
                default:
                    break
                }
            }
            let gift = KuniGramLocalGift(
                slug: unique.slug,
                title: unique.title,
                number: unique.number,
                modelName: modelName,
                backdropName: backdropName,
                symbolName: symbolName
            )
            let profileGift = ProfileGiftsContext.State.StarGift(
                gift: .unique(unique),
                reference: .slug(slug: unique.slug),
                fromPeer: nil,
                date: Int32(Date().timeIntervalSince1970),
                text: nil,
                entities: nil,
                nameHidden: false,
                savedToProfile: true,
                pinnedToTop: false,
                convertStars: nil,
                canUpgrade: false,
                canExportDate: nil,
                upgradeStars: nil,
                transferStars: 0,
                canTransferDate: nil,
                canResaleDate: nil,
                collectionIds: nil,
                prepaidUpgradeHash: nil,
                upgradeSeparate: false,
                dropOriginalDetailsStars: nil,
                number: unique.number,
                isRefunded: false,
                canCraftAt: nil
            )
            KuniGramLocalProfileGifts.shared.add(profileGift)
            self.gifts.insert(gift, at: 0)
            self.save()
            completion(gift)
        }, error: { [weak self] _ in
            guard let self = self else { return }
            let gift = KuniGramLocalGift(
                slug: cleanSlug,
                title: parsed.title,
                number: parsed.number,
                modelName: "Classic",
                backdropName: "Midnight",
                symbolName: "Peach"
            )
            self.gifts.insert(gift, at: 0)
            self.save()
            completion(gift)
        })
    }

    public func deleteGift(id: String) {
        if let gift = self.gifts.first(where: { $0.id == id }) {
            KuniGramLocalProfileGifts.shared.remove(slug: gift.slug)
        }
        self.gifts.removeAll { $0.id == id }
        if self.activeWalletCustomizationGiftId == id {
            self.activeWalletCustomizationGiftId = nil
        }
        self.save()
    }

    public func sendGiftToGramWallet(id: String) {
        guard let idx = self.gifts.firstIndex(where: { $0.id == id }) else { return }
        self.gifts[idx].inGramWallet = true
        self.gifts[idx].sentToPeerTitle = "Gram Wallet"
        self.save()
    }

    public func sendGiftLocallyToPeer(id: String, peerTitle: String, context: AccountContext? = nil, completion: ((Bool, String) -> Void)? = nil) {
        guard let idx = self.gifts.firstIndex(where: { $0.id == id }) else {
            completion?(false, peerTitle)
            return
        }
        let gift = self.gifts[idx]
        guard let context = context else {
            self.gifts.remove(at: idx)
            KuniGramLocalProfileGifts.shared.remove(slug: gift.slug)
            self.save()
            completion?(true, peerTitle)
            return
        }

        let trimmed = peerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "saved messages" || lower == "избранное" || lower == "me" {
            KuniGramLocalProfileGifts.shared.transferLocally(slug: gift.slug, account: context.account, toPeerId: context.account.peerId)
            self.gifts.removeAll { $0.id == id }
            self.save()
            completion?(true, trimmed)
            return
        }

        let cleanName = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        let resolveSignal: Signal<EnginePeer?, NoError> = context.engine.peers.resolvePeerByName(name: cleanName, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            switch result {
            case .progress:
                return .complete()
            case let .result(peer):
                return .single(peer)
            }
        }
        |> take(1)

        let _ = (resolveSignal
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
            guard let self = self else { return }
            if let peer = peer {
                KuniGramLocalProfileGifts.shared.transferLocally(slug: gift.slug, account: context.account, toPeerId: peer.id)
                self.gifts.removeAll { $0.id == id }
                self.save()
                completion?(true, peer.compactDisplayTitle)
            } else {
                let _ = (context.engine.messages.chatListPeers(group: .root, filterPredicate: nil, count: 100)
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] peers, _ in
                    guard let self = self else { return }
                    if let matched = peers.first(where: {
                        $0.compactDisplayTitle.lowercased() == lower ||
                        ($0.addressName?.lowercased() == cleanName.lowercased())
                    }) {
                        KuniGramLocalProfileGifts.shared.transferLocally(slug: gift.slug, account: context.account, toPeerId: matched.id)
                        self.gifts.removeAll { $0.id == id }
                        self.save()
                        completion?(true, matched.compactDisplayTitle)
                    } else {
                        completion?(false, trimmed)
                    }
                })
            }
        })
    }

    public func craftGift(from ids: [String]) -> KuniGramLocalGift? {
        let selected = self.gifts.filter { ids.contains($0.id) }
        guard let primary = selected.first else { return nil }
        let secondary = selected.count > 1 ? selected[1] : primary

        let crafted = KuniGramLocalGift(
            slug: "\(primary.slug)-Crafted",
            title: "\(primary.title) ✦ Crafted",
            number: primary.number,
            modelName: "\(primary.modelName) × \(secondary.modelName)",
            backdropName: secondary.backdropName,
            symbolName: primary.symbolName,
            isCrafted: true,
            inProfile: true,
            inGramWallet: primary.inGramWallet
        )
        self.gifts.removeAll { ids.contains($0.id) }
        self.gifts.insert(crafted, at: 0)
        self.save()
        return crafted
    }

    public func addWalletNFT(fromTonviewerLink rawLink: String, completion: @escaping (KuniGramWalletNFT?) -> Void) {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(nil)
            return
        }
        let address = trimmed.components(separatedBy: "/").last?.components(separatedBy: "?").first ?? trimmed
        guard let apiURL = URL(string: "https://tonapi.io/v2/nfts/\(address)") else {
            let fallback = KuniGramWalletNFT(id: UUID().uuidString, name: "NFT \(address.prefix(8))...", address: address, sourceUrl: trimmed, collectionName: "TON NFT")
            self.walletNFTs.insert(fallback, at: 0)
            self.save()
            completion(fallback)
            return
        }

        URLSession.shared.dataTask(with: apiURL) { [weak self] data, _, _ in
            var name = "NFT \(address.prefix(8))..."
            var collection = "TON Collection"
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let meta = json["metadata"] as? [String: Any], let n = meta["name"] as? String, !n.isEmpty {
                    name = n
                }
                if let col = json["collection"] as? [String: Any], let cn = col["name"] as? String, !cn.isEmpty {
                    collection = cn
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let nft = KuniGramWalletNFT(id: UUID().uuidString, name: name, address: address, sourceUrl: trimmed, collectionName: collection)
                self.walletNFTs.insert(nft, at: 0)
                self.save()
                completion(nft)
            }
        }.resume()
    }

    public func deleteWalletNFT(id: String) {
        self.walletNFTs.removeAll { $0.id == id }
        self.save()
    }

    private static func parseSlugFallback(_ slug: String) -> (title: String, number: Int32) {
        let parts = slug.split(separator: "-")
        let num = Int32(parts.last ?? "") ?? 1
        let rawName = parts.count > 1 ? parts.dropLast().joined(separator: " ") : slug
        var spaced = ""
        for ch in rawName {
            if ch.isUppercase && !spaced.isEmpty && spaced.last != " " {
                spaced.append(" ")
            }
            spaced.append(ch)
        }
        return (spaced.isEmpty ? slug : spaced, num)
    }
}
