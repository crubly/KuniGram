import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils

private enum KuniGramAdditionalSection: Int32 {
    case disguise
}

private enum KuniGramAdditionalEntry: ItemListNodeEntry {
    case disguiseToggle(PresentationTheme, String, Bool)
    case disguiseFooter(PresentationTheme, String)

    var section: ItemListSectionId {
        return KuniGramAdditionalSection.disguise.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .disguiseToggle: return 0
        case .disguiseFooter: return 1
        }
    }

    static func < (lhs: KuniGramAdditionalEntry, rhs: KuniGramAdditionalEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KuniGramAdditionalArguments
        switch self {
        case let .disguiseToggle(_, title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { enabled in
                    arguments.toggleDisguise(enabled)
                }
            )
        case let .disguiseFooter(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        }
    }
}

private final class KuniGramAdditionalArguments {
    let toggleDisguise: (Bool) -> Void

    init(toggleDisguise: @escaping (Bool) -> Void) {
        self.toggleDisguise = toggleDisguise
    }
}

public func kuniGramAdditionalSettingsController(context: AccountContext) -> ViewController {
    let disguiseEnabledPromise = ValuePromise<Bool>(KuniGramSettings.shared.isTelegramDisguiseEnabled, ignoreRepeated: false)

    let arguments = KuniGramAdditionalArguments(
        toggleDisguise: { enabled in
            KuniGramSettings.shared.isTelegramDisguiseEnabled = enabled
            disguiseEnabledPromise.set(enabled)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        disguiseEnabledPromise.get()
    )
    |> map { presentationData, isDisguiseEnabled -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = KuniGramStrings(presentationData: presentationData)
        let entries: [KuniGramAdditionalEntry] = [
            .disguiseToggle(presentationData.theme, strings.disguiseTitle, isDisguiseEnabled),
            .disguiseFooter(presentationData.theme, strings.disguiseFooter)
        ]

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(strings.additionalSettingsTitle),
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

    return ItemListController(context: context, state: signal)
}
