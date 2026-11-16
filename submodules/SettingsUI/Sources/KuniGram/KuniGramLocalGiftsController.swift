import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import UndoUI

private enum KuniGramGiftsSection: Int32 {
    case actions
    case list
}

private enum KuniGramGiftsEntry: ItemListNodeEntry {
    case addBySlug(PresentationTheme, String)
    case craftAction(PresentationTheme, String)
    case listHeader(PresentationTheme, String)
    case giftItem(Int32, PresentationTheme, KuniGramLocalGift)
    case emptyText(PresentationTheme, String)
    case footer(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .addBySlug, .craftAction:
            return KuniGramGiftsSection.actions.rawValue
        case .listHeader, .giftItem, .emptyText, .footer:
            return KuniGramGiftsSection.list.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .addBySlug: return 0
        case .craftAction: return 1
        case .listHeader: return 2
        case let .giftItem(index, _, _): return 100 + index
        case .emptyText: return 3
        case .footer: return 9999
        }
    }

    static func == (lhs: KuniGramGiftsEntry, rhs: KuniGramGiftsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.addBySlug(lt, ls), .addBySlug(rt, rs)): return lt === rt && ls == rs
        case let (.craftAction(lt, ls), .craftAction(rt, rs)): return lt === rt && ls == rs
        case let (.listHeader(lt, ls), .listHeader(rt, rs)): return lt === rt && ls == rs
        case let (.giftItem(li, lt, lg), .giftItem(ri, rt, rg)): return li == ri && lt === rt && lg == rg
        case let (.emptyText(lt, ls), .emptyText(rt, rs)): return lt === rt && ls == rs
        case let (.footer(lt, ls), .footer(rt, rs)): return lt === rt && ls == rs
        default: return false
        }
    }

    static func < (lhs: KuniGramGiftsEntry, rhs: KuniGramGiftsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KuniGramGiftsArguments
        switch self {
        case let .addBySlug(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.promptAddSlug() }
            )
        case let .craftAction(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.craftLatest() }
            )
        case let .listHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .giftItem(_, _, gift):
            let badge = gift.inGramWallet ? "Wallet" : (gift.sentToPeerTitle ?? "#\(gift.number)")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.premium,
                title: "\(gift.title) #\(gift.number)",
                label: badge,
                additionalDetailLabel: "\(gift.modelName) • \(gift.backdropName) • \(gift.symbolName)",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openGiftActions(gift) }
            )
        case let .emptyText(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class KuniGramGiftsArguments {
    let promptAddSlug: () -> Void
    let craftLatest: () -> Void
    let openGiftActions: (KuniGramLocalGift) -> Void

    init(
        promptAddSlug: @escaping () -> Void,
        craftLatest: @escaping () -> Void,
        openGiftActions: @escaping (KuniGramLocalGift) -> Void
    ) {
        self.promptAddSlug = promptAddSlug
        self.craftLatest = craftLatest
        self.openGiftActions = openGiftActions
    }
}

public func kuniGramLocalGiftsController(context: AccountContext) -> ViewController {
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

    let promptAddSlugImpl: () -> Void = {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
        let alert = UIAlertController(
            title: isRu ? "Добавить NFT-подарок" : "Add NFT Gift",
            message: isRu ? "Введите слаг подарка (например: PlushPepe-13)" : "Enter gift slug (e.g. PlushPepe-13)",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "PlushPepe-13"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: isRu ? "Добавить" : "Add", style: .default, handler: { _ in
            let slug = alert.textFields?.first?.text ?? ""
            guard !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            KuniGramLocalGiftStore.shared.addGiftBySlug(slug, context: context) { gift in
                showToast((isRu ? "Добавлен: " : "Added: ") + "\(gift.title) #\(gift.number)")
            }
        }))
        presentUIKitImpl?(alert)
    }

    let arguments = KuniGramGiftsArguments(
        promptAddSlug: promptAddSlugImpl,
        craftLatest: {
            let gifts = KuniGramLocalGiftStore.shared.gifts
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            guard gifts.count >= 2 else {
                showToast(isRu ? "Нужно минимум 2 подарка для крафта" : "Need at least 2 gifts to craft")
                return
            }
            if let crafted = KuniGramLocalGiftStore.shared.craftGift(from: [gifts[0].id, gifts[1].id]) {
                showToast((isRu ? "Скрафчен: " : "Crafted: ") + crafted.title)
            }
        },
        openGiftActions: { gift in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            let sheet = UIAlertController(
                title: "\(gift.title) #\(gift.number)",
                message: "\(gift.modelName) • \(gift.backdropName) • \(gift.symbolName)",
                preferredStyle: .actionSheet
            )
            sheet.addAction(UIAlertAction(
                title: isRu ? "Отправить в чат (локальный визуал)" : "Send to Chat (Local Visual)",
                style: .default,
                handler: { _ in
                    let peerAlert = UIAlertController(
                        title: isRu ? "Получатель" : "Recipient",
                        message: isRu ? "Введите @username или имя чата" : "Enter @username or chat name",
                        preferredStyle: .alert
                    )
                    peerAlert.addTextField { $0.placeholder = "@username" }
                    peerAlert.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
                    peerAlert.addAction(UIAlertAction(title: isRu ? "Отправить" : "Send", style: .default, handler: { _ in
                        let target = peerAlert.textFields?.first?.text ?? "Saved Messages"
                        let clean = target.isEmpty ? "Saved Messages" : target
                        KuniGramLocalGiftStore.shared.sendGiftLocallyToPeer(id: gift.id, peerTitle: clean, context: context) { ok, resolvedTitle in
                            if ok {
                                showToast((isRu ? "Визуально отправлено → " : "Visually sent → ") + resolvedTitle)
                            } else {
                                showToast((isRu ? "Чат не найден: " : "Chat not found: ") + resolvedTitle)
                            }
                        }
                    }))
                    presentUIKitImpl?(peerAlert)
                }
            ))
            sheet.addAction(UIAlertAction(
                title: isRu ? "Отправить на Gram Wallet" : "Send to Gram Wallet",
                style: .default,
                handler: { _ in
                    KuniGramLocalGiftStore.shared.sendGiftToGramWallet(id: gift.id)
                    showToast(isRu ? "Подарок добавлен в Gram Wallet" : "Gift sent to Gram Wallet")
                }
            ))
            sheet.addAction(UIAlertAction(
                title: isRu ? "Удалить" : "Delete",
                style: .destructive,
                handler: { _ in
                    KuniGramLocalGiftStore.shared.deleteGift(id: gift.id)
                }
            ))
            sheet.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
            presentUIKitImpl?(sheet)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        versionPromise.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let isRu = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
        let gifts = KuniGramLocalGiftStore.shared.gifts

        var entries: [KuniGramGiftsEntry] = [
            .addBySlug(presentationData.theme, isRu ? "+ Добавить подарок по слагу (PlushPepe-13)" : "+ Add Gift by Slug (PlushPepe-13)"),
            .craftAction(presentationData.theme, isRu ? "✦ Крафтить 2 последних подарка" : "✦ Craft 2 Latest Gifts"),
            .listHeader(presentationData.theme, isRu ? "КОЛЛЕКЦИОННЫЕ NFT-ПОДАРКИ (\(gifts.count))" : "COLLECTIBLE NFT GIFTS (\(gifts.count))")
        ]

        if gifts.isEmpty {
            entries.append(.emptyText(presentationData.theme, isRu ? "Нет локальных подарков. Нажмите + чтобы добавить по слагу." : "No local gifts yet. Tap + to add by slug."))
        } else {
            for (idx, gift) in gifts.enumerated() {
                entries.append(.giftItem(Int32(idx), presentationData.theme, gift))
            }
        }
        entries.append(.footer(presentationData.theme, isRu
            ? "Локальные коллекционные подарки с подгрузкой реальных моделей и атрибутов из Telegram. Их можно визуально отправлять в чаты, на Gram Wallet и крафтить."
            : "Local collectible NFT gifts with real Telegram model attributes. You can visually send them to chats, send to Gram Wallet, and craft them."
        ))

        let rightButton = ItemListNavigationButton(
            content: .icon(.add),
            style: .regular,
            enabled: true,
            action: { promptAddSlugImpl() }
        )

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(isRu ? "Подарки" : "Gifts"),
            leftNavigationButton: nil,
            rightNavigationButton: rightButton,
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
