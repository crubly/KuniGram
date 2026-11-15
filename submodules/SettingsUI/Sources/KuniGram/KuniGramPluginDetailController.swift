import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils

private enum KuniGramPluginDetailSection: Int32 {
    case info
    case actions
    case logs
    case code
}

private enum KuniGramPluginDetailEntry: ItemListNodeEntry {
    case enabledToggle(PresentationTheme, String, Bool)
    case author(PresentationTheme, String, String)
    case version(PresentationTheme, String, String)
    case descriptionText(PresentationTheme, String)
    case rerunAction(PresentationTheme, String)
    case deleteAction(PresentationTheme, String)
    case logsHeader(PresentationTheme, String)
    case logsBody(PresentationTheme, String)
    case codeHeader(PresentationTheme, String)
    case codeBody(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .enabledToggle, .author, .version, .descriptionText:
            return KuniGramPluginDetailSection.info.rawValue
        case .rerunAction, .deleteAction:
            return KuniGramPluginDetailSection.actions.rawValue
        case .logsHeader, .logsBody:
            return KuniGramPluginDetailSection.logs.rawValue
        case .codeHeader, .codeBody:
            return KuniGramPluginDetailSection.code.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .enabledToggle: return 0
        case .author: return 1
        case .version: return 2
        case .descriptionText: return 3
        case .rerunAction: return 4
        case .deleteAction: return 5
        case .logsHeader: return 6
        case .logsBody: return 7
        case .codeHeader: return 8
        case .codeBody: return 9
        }
    }

    static func < (lhs: KuniGramPluginDetailEntry, rhs: KuniGramPluginDetailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KuniGramPluginDetailArguments
        switch self {
        case let .enabledToggle(_, title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { enabled in
                    arguments.toggleEnabled(enabled)
                }
            )
        case let .author(_, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: nil
            )
        case let .version(_, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: nil
            )
        case let .descriptionText(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .rerunAction(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.rerun()
                }
            )
        case let .deleteAction(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .destructive,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.deletePlugin()
                }
            )
        case let .logsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .logsBody(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .codeHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .codeBody(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class KuniGramPluginDetailArguments {
    let toggleEnabled: (Bool) -> Void
    let rerun: () -> Void
    let deletePlugin: () -> Void

    init(
        toggleEnabled: @escaping (Bool) -> Void,
        rerun: @escaping () -> Void,
        deletePlugin: @escaping () -> Void
    ) {
        self.toggleEnabled = toggleEnabled
        self.rerun = rerun
        self.deletePlugin = deletePlugin
    }
}

public func kuniGramPluginDetailController(context: AccountContext, pluginId: String) -> ViewController {
    var dismissImpl: (() -> Void)?
    var presentImpl: ((ViewController) -> Void)?

    let refreshPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshCounter = 0
    let bumpRefresh: () -> Void = {
        refreshCounter += 1
        refreshPromise.set(refreshCounter)
    }

    let observer = NotificationCenter.default.addObserver(
        forName: KuniGramPluginEngine.pluginsDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        bumpRefresh()
    }

    let arguments = KuniGramPluginDetailArguments(
        toggleEnabled: { enabled in
            KuniGramPluginEngine.shared.setPluginEnabled(id: pluginId, enabled: enabled, context: context)
            bumpRefresh()
        },
        rerun: {
            KuniGramPluginEngine.shared.rerunOnLoad(id: pluginId, context: context)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bumpRefresh()
            }
        },
        deletePlugin: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let strings = KuniGramStrings(presentationData: presentationData)
            let alert = textAlertController(
                context: context,
                title: strings.deleteConfirmTitle,
                text: "",
                actions: [
                    TextAlertAction(type: .destructiveAction, title: strings.deleteTitle, action: {
                        KuniGramPluginEngine.shared.deletePlugin(id: pluginId)
                        dismissImpl?()
                    }),
                    TextAlertAction(type: .defaultAction, title: strings.cancelTitle, action: {})
                ]
            )
            presentImpl?(alert)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        refreshPromise.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = KuniGramStrings(presentationData: presentationData)
        let plugin = KuniGramPluginEngine.shared.plugins.first(where: { $0.id == pluginId })
        let title = plugin?.name ?? strings.pluginDetailsTitle

        var entries: [KuniGramPluginDetailEntry] = [
            .enabledToggle(presentationData.theme, strings.pluginEnabledTitle, plugin?.isEnabled ?? false),
            .author(presentationData.theme, strings.pluginAuthorTitle, plugin?.author ?? "-"),
            .version(presentationData.theme, strings.pluginVersionTitle, plugin?.version ?? "1.0")
        ]
        if let desc = plugin?.description, !desc.isEmpty {
            entries.append(.descriptionText(presentationData.theme, desc))
        }
        entries.append(.rerunAction(presentationData.theme, strings.pluginRunTestTitle))
        entries.append(.deleteAction(presentationData.theme, strings.pluginDeleteTitle))

        let logs = KuniGramPluginEngine.shared.logs(for: pluginId)
        entries.append(.logsHeader(presentationData.theme, strings.pluginLogsHeader))
        entries.append(.logsBody(presentationData.theme, logs.isEmpty ? "—" : logs.suffix(15).joined(separator: "\n")))

        let code = KuniGramPluginEngine.shared.sourceCode(for: pluginId)
        let previewCode = code.count > 2000 ? String(code.prefix(2000)) + "\n..." : code
        entries.append(.codeHeader(presentationData.theme, strings.pluginCodeHeader))
        entries.append(.codeBody(presentationData.theme, previewCode.isEmpty ? "—" : previewCode))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
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
    dismissImpl = { [weak controller] in
        (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
