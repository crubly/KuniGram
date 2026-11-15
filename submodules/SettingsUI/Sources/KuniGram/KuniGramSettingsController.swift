import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils

private enum KuniGramSettingsSection: Int32 {
    case plugins
    case other
    case additional
}

private enum KuniGramSettingsEntry: ItemListNodeEntry {
    case pluginsHeader(PresentationTheme, String)
    case pluginsEngine(PresentationTheme, String, String)
    case otherHeader(PresentationTheme, String)
    case gifts(PresentationTheme, String, String)
    case gramWallet(PresentationTheme, String, String)
    case additionalSettings(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .pluginsHeader, .pluginsEngine:
            return KuniGramSettingsSection.plugins.rawValue
        case .otherHeader, .gifts, .gramWallet:
            return KuniGramSettingsSection.other.rawValue
        case .additionalSettings:
            return KuniGramSettingsSection.additional.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .pluginsHeader: return 0
        case .pluginsEngine: return 1
        case .otherHeader: return 2
        case .gifts: return 3
        case .gramWallet: return 4
        case .additionalSettings: return 5
        }
    }

    static func < (lhs: KuniGramSettingsEntry, rhs: KuniGramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KuniGramSettingsArguments
        switch self {
        case let .pluginsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .pluginsEngine(_, title, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.dataAndStorage,
                title: title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openPluginsEngine() }
            )
        case let .otherHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .gifts(_, title, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.premium,
                title: title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openGifts() }
            )
        case let .gramWallet(_, title, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.stars,
                title: title,
                label: label,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openGramWallet() }
            )
        case let .additionalSettings(_, title):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                icon: PresentationResourcesSettings.appearance,
                title: title,
                label: "",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.openAdditionalSettings() }
            )
        }
    }
}

private final class KuniGramSettingsArguments {
    let openPluginsEngine: () -> Void
    let openGifts: () -> Void
    let openGramWallet: () -> Void
    let openAdditionalSettings: () -> Void

    init(
        openPluginsEngine: @escaping () -> Void,
        openGifts: @escaping () -> Void,
        openGramWallet: @escaping () -> Void,
        openAdditionalSettings: @escaping () -> Void
    ) {
        self.openPluginsEngine = openPluginsEngine
        self.openGifts = openGifts
        self.openGramWallet = openGramWallet
        self.openAdditionalSettings = openAdditionalSettings
    }
}

public func kuniGramSettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let pluginsVersion = ValuePromise<Int>(0, ignoreRepeated: false)
    var currentVersion = 0
    let bump: () -> Void = {
        currentVersion += 1
        pluginsVersion.set(currentVersion)
    }
    let observer1 = NotificationCenter.default.addObserver(
        forName: KuniGramPluginEngine.pluginsDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in bump() }
    let observer2 = NotificationCenter.default.addObserver(
        forName: KuniGramLocalGiftStore.didChangeNotification,
        object: nil,
        queue: .main
    ) { _ in bump() }

    let arguments = KuniGramSettingsArguments(
        openPluginsEngine: {
            pushControllerImpl?(kuniGramPluginsController(context: context))
        },
        openGifts: {
            pushControllerImpl?(kuniGramLocalGiftsController(context: context))
        },
        openGramWallet: {
            pushControllerImpl?(kuniGramGramWalletController(context: context))
        },
        openAdditionalSettings: {
            pushControllerImpl?(kuniGramAdditionalSettingsController(context: context))
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        pluginsVersion.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = KuniGramStrings(presentationData: presentationData)
        let plugins = KuniGramPluginEngine.shared.plugins
        let activeCount = plugins.filter { $0.isEnabled }.count
        let countLabel = plugins.isEmpty ? "0" : "\(activeCount)/\(plugins.count)"
        let giftsCount = KuniGramLocalGiftStore.shared.gifts.count
        let walletLabel = KuniGramLocalGiftStore.shared.isGramWalletEnabled
            ? String(format: "%.2f TON", KuniGramLocalGiftStore.shared.gramWalletBalanceTON)
            : "Off"

        let entries: [KuniGramSettingsEntry] = [
            .pluginsHeader(presentationData.theme, strings.pluginsEngineHeader),
            .pluginsEngine(presentationData.theme, strings.pluginsEngineTitle, countLabel),
            .otherHeader(presentationData.theme, strings.otherHeader),
            .gifts(presentationData.theme, strings.giftsTitle, giftsCount == 0 ? "" : "\(giftsCount)"),
            .gramWallet(presentationData.theme, strings.gramWalletTitle, walletLabel),
            .additionalSettings(presentationData.theme, strings.additionalSettingsTitle)
        ]

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(strings.kuniGramTitle),
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
        _ = observer1
        _ = observer2
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
