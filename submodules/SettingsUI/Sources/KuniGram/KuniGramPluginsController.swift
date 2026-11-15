import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import UndoUI

private enum KuniGramPluginsSection: Int32 {
    case actions
    case list
}

private enum KuniGramPluginsEntry: ItemListNodeEntry {
    case loadPlugin(PresentationTheme, String)
    case pastePlugin(PresentationTheme, String)
    case pluginsHeader(PresentationTheme, String)
    case pluginItem(Int32, PresentationTheme, KuniGramPlugin)
    case emptyPlaceholder(PresentationTheme, String)
    case footer(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .loadPlugin, .pastePlugin:
            return KuniGramPluginsSection.actions.rawValue
        case .pluginsHeader, .pluginItem, .emptyPlaceholder, .footer:
            return KuniGramPluginsSection.list.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .loadPlugin: return 0
        case .pastePlugin: return 1
        case .pluginsHeader: return 2
        case let .pluginItem(index, _, _): return 100 + index
        case .emptyPlaceholder: return 3
        case .footer: return 9999
        }
    }

    static func == (lhs: KuniGramPluginsEntry, rhs: KuniGramPluginsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.loadPlugin(lt, ls), .loadPlugin(rt, rs)):
            return lt === rt && ls == rs
        case let (.pastePlugin(lt, ls), .pastePlugin(rt, rs)):
            return lt === rt && ls == rs
        case let (.pluginsHeader(lt, ls), .pluginsHeader(rt, rs)):
            return lt === rt && ls == rs
        case let (.pluginItem(li, lt, lp), .pluginItem(ri, rt, rp)):
            return li == ri && lt === rt && lp == rp
        case let (.emptyPlaceholder(lt, ls), .emptyPlaceholder(rt, rs)):
            return lt === rt && ls == rs
        case let (.footer(lt, ls), .footer(rt, rs)):
            return lt === rt && ls == rs
        default:
            return false
        }
    }

    static func < (lhs: KuniGramPluginsEntry, rhs: KuniGramPluginsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KuniGramPluginsArguments
        switch self {
        case let .loadPlugin(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.pickPluginFile()
                }
            )
        case let .pastePlugin(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.pastePluginFromClipboard()
                }
            )
        case let .pluginsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .pluginItem(_, _, plugin):
            let subtitle: String
            if let error = plugin.lastError {
                subtitle = "by \(plugin.author) • Error: \(error)"
            } else {
                subtitle = "by \(plugin.author) • v\(plugin.version)"
            }
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: plugin.name,
                text: subtitle,
                textColor: plugin.lastError != nil ? .accent : .primary,
                value: plugin.isEnabled,
                maximumNumberOfLines: 2,
                sectionId: self.section,
                style: .blocks,
                updated: { enabled in
                    arguments.togglePlugin(plugin.id, enabled)
                },
                action: {
                    arguments.openPluginDetails(plugin)
                }
            )
        case let .emptyPlaceholder(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        case let .footer(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        }
    }
}

private final class KuniGramPluginsArguments {
    let pickPluginFile: () -> Void
    let pastePluginFromClipboard: () -> Void
    let togglePlugin: (String, Bool) -> Void
    let openPluginDetails: (KuniGramPlugin) -> Void

    init(
        pickPluginFile: @escaping () -> Void,
        pastePluginFromClipboard: @escaping () -> Void,
        togglePlugin: @escaping (String, Bool) -> Void,
        openPluginDetails: @escaping (KuniGramPlugin) -> Void
    ) {
        self.pickPluginFile = pickPluginFile
        self.pastePluginFromClipboard = pastePluginFromClipboard
        self.togglePlugin = togglePlugin
        self.openPluginDetails = openPluginDetails
    }
}

private final class KuniGramDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            self.onPick(url)
        }
    }
}

public func kuniGramPluginsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var presentUIKitImpl: ((UIViewController) -> Void)?
    var pickerDelegateHolder: KuniGramDocumentPickerDelegate?

    let pluginsVersion = ValuePromise<Int>(0, ignoreRepeated: false)
    var currentVersion = 0
    let observer = NotificationCenter.default.addObserver(
        forName: KuniGramPluginEngine.pluginsDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        currentVersion += 1
        pluginsVersion.set(currentVersion)
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

    let arguments = KuniGramPluginsArguments(
        pickPluginFile: {
            let delegate = KuniGramDocumentPickerDelegate { url in
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let strings = KuniGramStrings(presentationData: presentationData)
                do {
                    _ = try KuniGramPluginEngine.shared.importPlugin(from: url, context: context)
                    showToast(strings.importedToast)
                } catch {
                    let alert = textAlertController(
                        context: context,
                        title: strings.importErrorTitle,
                        text: error.localizedDescription,
                        actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                    )
                    presentControllerImpl?(alert)
                }
            }
            pickerDelegateHolder = delegate

            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
                picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pythonScript, .plainText, .data])
            } else {
                picker = UIDocumentPickerViewController(documentTypes: ["public.python-script", "public.plain-text", "public.data"], in: .import)
            }
            picker.delegate = delegate
            picker.allowsMultipleSelection = false
            presentUIKitImpl?(picker)
        },
        pastePluginFromClipboard: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let strings = KuniGramStrings(presentationData: presentationData)
            guard let code = UIPasteboard.general.string, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showToast(strings.clipboardEmptyToast)
                return
            }
            let fileName = "plugin_\(Int(Date().timeIntervalSince1970)).py"
            do {
                _ = try KuniGramPluginEngine.shared.importPlugin(code: code, fileName: fileName, context: context)
                showToast(strings.importedToast)
            } catch {
                let alert = textAlertController(
                    context: context,
                    title: strings.importErrorTitle,
                    text: error.localizedDescription,
                    actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                )
                presentControllerImpl?(alert)
            }
        },
        togglePlugin: { id, enabled in
            KuniGramPluginEngine.shared.setPluginEnabled(id: id, enabled: enabled, context: context)
        },
        openPluginDetails: { plugin in
            pushControllerImpl?(kuniGramPluginDetailController(context: context, pluginId: plugin.id))
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        pluginsVersion.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = KuniGramStrings(presentationData: presentationData)
        let plugins = KuniGramPluginEngine.shared.plugins

        var entries: [KuniGramPluginsEntry] = [
            .loadPlugin(presentationData.theme, strings.loadPluginTitle),
            .pastePlugin(presentationData.theme, strings.pastePluginTitle),
            .pluginsHeader(presentationData.theme, strings.installedPluginsHeader)
        ]

        if plugins.isEmpty {
            entries.append(.emptyPlaceholder(presentationData.theme, strings.noPluginsTitle))
        } else {
            for (index, plugin) in plugins.enumerated() {
                entries.append(.pluginItem(Int32(index), presentationData.theme, plugin))
            }
        }
        entries.append(.footer(presentationData.theme, strings.pluginsFooter))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(strings.pluginsEngineTitle),
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
        _ = pickerDelegateHolder
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentUIKitImpl = { [weak controller] vc in
        controller?.view.window?.rootViewController?.present(vc, animated: true)
    }
    return controller
}
