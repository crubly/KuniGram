import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import UndoUI

private enum GramWalletSection: Int32 {
    case main
    case balance
    case walletGifts
    case tonviewerNFTs
}

private enum GramWalletEntry: ItemListNodeEntry {
    case enableToggle(PresentationTheme, String, Bool)
    case customizationBanner(PresentationTheme, String, String)
    case balanceRow(PresentationTheme, String, String)
    case addTonviewerNFT(PresentationTheme, String)
    case giftsHeader(PresentationTheme, String)
    case walletGiftItem(Int32, PresentationTheme, KuniGramLocalGift, Bool)
    case noGiftsText(PresentationTheme, String)
    case nftsHeader(PresentationTheme, String)
    case tonviewerNFTItem(Int32, PresentationTheme, KuniGramWalletNFT)
    case noNFTsText(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .enableToggle, .customizationBanner:
            return GramWalletSection.main.rawValue
        case .balanceRow, .addTonviewerNFT:
            return GramWalletSection.balance.rawValue
        case .giftsHeader, .walletGiftItem, .noGiftsText:
            return GramWalletSection.walletGifts.rawValue
        case .nftsHeader, .tonviewerNFTItem, .noNFTsText:
            return GramWalletSection.tonviewerNFTs.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .enableToggle: return 0
        case .customizationBanner: return 1
        case .balanceRow: return 2
        case .addTonviewerNFT: return 3
        case .giftsHeader: return 4
        case let .walletGiftItem(i, _, _, _): return 100 + i
        case .noGiftsText: return 5
        case .nftsHeader: return 6
        case let .tonviewerNFTItem(i, _, _): return 500 + i
        case .noNFTsText: return 7
        }
    }

    static func == (lhs: GramWalletEntry, rhs: GramWalletEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.enableToggle(lt, ls, lv), .enableToggle(rt, rs, rv)): return lt === rt && ls == rs && lv == rv
        case let (.customizationBanner(lt, ls, ll), .customizationBanner(rt, rs, rl)): return lt === rt && ls == rs && ll == rl
        case let (.balanceRow(lt, ls, ll), .balanceRow(rt, rs, rl)): return lt === rt && ls == rs && ll == rl
        case let (.addTonviewerNFT(lt, ls), .addTonviewerNFT(rt, rs)): return lt === rt && ls == rs
        case let (.giftsHeader(lt, ls), .giftsHeader(rt, rs)): return lt === rt && ls == rs
        case let (.walletGiftItem(li, lt, lg, la), .walletGiftItem(ri, rt, rg, ra)): return li == ri && lt === rt && lg == rg && la == ra
        case let (.noGiftsText(lt, ls), .noGiftsText(rt, rs)): return lt === rt && ls == rs
        case let (.nftsHeader(lt, ls), .nftsHeader(rt, rs)): return lt === rt && ls == rs
        case let (.tonviewerNFTItem(li, lt, ln), .tonviewerNFTItem(ri, rt, rn)): return li == ri && lt === rt && ln == rn
        case let (.noNFTsText(lt, ls), .noNFTsText(rt, rs)): return lt === rt && ls == rs
        default: return false
        }
    }

    static func < (lhs: GramWalletEntry, rhs: GramWalletEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! GramWalletArguments
        switch self {
        case let .enableToggle(_, title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { enabled in arguments.toggleEnabled(enabled) }
            )
        case let .customizationBanner(_, title, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.appearance,
                title: title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: { arguments.clearCustomization() }
            )
        case let .balanceRow(_, title, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.stars,
                title: title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.editBalance() }
            )
        case let .addTonviewerNFT(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.addTonviewerNFT() }
            )
        case let .giftsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .walletGiftItem(_, _, gift, isActive):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.premium,
                title: "\(gift.title) #\(gift.number)",
                label: isActive ? "✓ Active" : "Apply",
                additionalDetailLabel: "\(gift.modelName) • \(gift.backdropName)",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.applyGiftCustomization(gift) }
            )
        case let .noGiftsText(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .nftsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .tonviewerNFTItem(_, _, nft):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: nft.name,
                label: nft.collectionName,
                additionalDetailLabel: nft.address,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.deleteNFT(nft) }
            )
        case let .noNFTsText(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class GramWalletArguments {
    let toggleEnabled: (Bool) -> Void
    let editBalance: () -> Void
    let addTonviewerNFT: () -> Void
    let applyGiftCustomization: (KuniGramLocalGift) -> Void
    let clearCustomization: () -> Void
    let deleteNFT: (KuniGramWalletNFT) -> Void

    init(
        toggleEnabled: @escaping (Bool) -> Void,
        editBalance: @escaping () -> Void,
        addTonviewerNFT: @escaping () -> Void,
        applyGiftCustomization: @escaping (KuniGramLocalGift) -> Void,
        clearCustomization: @escaping () -> Void,
        deleteNFT: @escaping (KuniGramWalletNFT) -> Void
    ) {
        self.toggleEnabled = toggleEnabled
        self.editBalance = editBalance
        self.addTonviewerNFT = addTonviewerNFT
        self.applyGiftCustomization = applyGiftCustomization
        self.clearCustomization = clearCustomization
        self.deleteNFT = deleteNFT
    }
}

public func kuniGramGramWalletController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?
    var presentUIKitImpl: ((UIViewController) -> Void)?

    let versionPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let observer = NotificationCenter.default.addObserver(
        forName: KuniGramLocalGiftStore.didChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        version += 1
        versionPromise.set(version)
    }

    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let toast = UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: 2.5, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return false }
        )
        presentControllerImpl?(toast)
    }

    let arguments = GramWalletArguments(
        toggleEnabled: { enabled in
            KuniGramLocalGiftStore.shared.isGramWalletEnabled = enabled
        },
        editBalance: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            let alert = UIAlertController(
                title: isRu ? "Баланс Gram Wallet" : "Gram Wallet Balance",
                message: isRu ? "Введите сумму в TON" : "Enter TON amount",
                preferredStyle: .alert
            )
            alert.addTextField { tf in
                tf.keyboardType = .decimalPad
                tf.text = String(format: "%.2f", KuniGramLocalGiftStore.shared.gramWalletBalanceTON)
            }
            alert.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: isRu ? "Сохранить" : "Save", style: .default, handler: { _ in
                let raw = (alert.textFields?.first?.text ?? "0").replacingOccurrences(of: ",", with: ".")
                if let val = Double(raw) {
                    KuniGramLocalGiftStore.shared.gramWalletBalanceTON = max(0.0, val)
                }
            }))
            presentUIKitImpl?(alert)
        },
        addTonviewerNFT: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            let alert = UIAlertController(
                title: isRu ? "Выдать NFT через Tonviewer" : "Add NFT via Tonviewer",
                message: isRu ? "Вставьте ссылку на NFT с tonviewer.com" : "Paste tonviewer.com NFT link",
                preferredStyle: .alert
            )
            alert.addTextField { tf in
                tf.placeholder = "https://tonviewer.com/EQ..."
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }
            alert.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: isRu ? "Добавить" : "Add", style: .default, handler: { _ in
                let link = alert.textFields?.first?.text ?? ""
                KuniGramLocalGiftStore.shared.addWalletNFT(fromTonviewerLink: link) { nft in
                    if let nft = nft {
                        showToast((isRu ? "NFT добавлен: " : "NFT added: ") + nft.name)
                    }
                }
            }))
            presentUIKitImpl?(alert)
        },
        applyGiftCustomization: { gift in
            KuniGramLocalGiftStore.shared.activeWalletCustomizationGiftId = gift.id
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            showToast((isRu ? "Скин применён: " : "Applied skin: ") + "\(gift.title) #\(gift.number)")
        },
        clearCustomization: {
            KuniGramLocalGiftStore.shared.activeWalletCustomizationGiftId = nil
        },
        deleteNFT: { nft in
            KuniGramLocalGiftStore.shared.deleteWalletNFT(id: nft.id)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        versionPromise.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
        let store = KuniGramLocalGiftStore.shared
        let walletGifts = store.gifts.filter { $0.inGramWallet }
        let activeGift = store.activeWalletCustomizationGift
        let balanceStr = String(format: "%.2f TON", store.gramWalletBalanceTON)

        var entries: [GramWalletEntry] = [
            .enableToggle(presentationData.theme, isRu ? "Показывать в Настройках" : "Show in Settings", store.isGramWalletEnabled),
            .customizationBanner(
                presentationData.theme,
                isRu ? "Кастомизация кошелька" : "Wallet Customization",
                activeGift.map { "\($0.title) #\($0.number)" } ?? (isRu ? "Стандарт" : "Default")
            ),
            .balanceRow(presentationData.theme, isRu ? "Баланс" : "Balance", balanceStr),
            .addTonviewerNFT(presentationData.theme, isRu ? "+ Выдать NFT по ссылке Tonviewer" : "+ Add NFT via Tonviewer Link"),
            .giftsHeader(presentationData.theme, isRu ? "ПОДАРКИ В КОШЕЛЬКЕ (КАСТОМИЗАЦИЯ)" : "WALLET GIFTS (CUSTOMIZE)")
        ]

        if walletGifts.isEmpty {
            entries.append(.noGiftsText(presentationData.theme, isRu ? "Отправьте подарок из раздела «Подарки» на Gram Wallet, чтобы кастомизировать кошелёк." : "Send a gift from Gifts to Gram Wallet to customize it."))
        } else {
            for (idx, gift) in walletGifts.enumerated() {
                entries.append(.walletGiftItem(Int32(idx), presentationData.theme, gift, gift.id == activeGift?.id))
            }
        }

        entries.append(.nftsHeader(presentationData.theme, isRu ? "NFT ИЗ TONVIEWER (\(store.walletNFTs.count))" : "TONVIEWER NFTS (\(store.walletNFTs.count))"))
        if store.walletNFTs.isEmpty {
            entries.append(.noNFTsText(presentationData.theme, isRu ? "Нет добавленных NFT с Tonviewer." : "No Tonviewer NFTs added."))
        } else {
            for (idx, nft) in store.walletNFTs.enumerated() {
                entries.append(.tonviewerNFTItem(Int32(idx), presentationData.theme, nft))
            }
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(isRu ? "Gram Кошелёк" : "Gram Wallet"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.willDisappear = { _ in
        _ = observer
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentUIKitImpl = { [weak controller] vc in
        controller?.view.window?.rootViewController?.present(vc, animated: true)
    }
    return controller
}
