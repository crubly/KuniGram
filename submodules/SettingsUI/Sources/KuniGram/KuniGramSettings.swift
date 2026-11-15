import Foundation
import UIKit
import TelegramPresentationData

public final class KuniGramSettings {
    public static let shared = KuniGramSettings()

    private let disguiseKey = "kunigram_telegram_disguise_enabled"
    private let enabledPluginsKey = "kunigram_enabled_plugins"

    public static let disguiseDidChangeNotification = Notification.Name("KuniGramDisguiseDidChangeNotification")

    private init() {}

    public var isTelegramDisguiseEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: self.disguiseKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.disguiseKey)
            self.applyDisguise(enabled: newValue)
            NotificationCenter.default.post(name: Self.disguiseDidChangeNotification, object: nil)
        }
    }

    public func applyDisguise(enabled: Bool) {
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                return
            }
            let targetIcon: String? = enabled ? "BlueIcon" : nil
            if UIApplication.shared.alternateIconName != targetIcon {
                UIApplication.shared.setAlternateIconName(targetIcon) { _ in }
            }
        }
    }

    public var enabledPluginIds: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: self.enabledPluginsKey) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: self.enabledPluginsKey)
        }
    }

    public var appDisplayTitle: String {
        return self.isTelegramDisguiseEnabled ? "Telegram" : "KuniGram"
    }
}

public struct KuniGramStrings {
    private let isRussian: Bool

    public init(presentationData: PresentationData) {
        let lang = presentationData.strings.primaryComponent.languageCode.lowercased()
        self.isRussian = lang.hasPrefix("ru") || Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true
    }

    public var kuniGramTitle: String { "KuniGram" }
    public var pluginsEngineTitle: String { self.isRussian ? "Ядро Плагинов" : "Plugins Engine" }
    public var pluginsEngineHeader: String { self.isRussian ? "УПРАВЛЕНИЕ ПЛАГИНАМИ (PYTHON)" : "PLUGIN MANAGEMENT (PYTHON)" }
    public var additionalSettingsTitle: String { self.isRussian ? "Дополнительные настройки" : "Additional Settings" }
    public var loadPluginTitle: String { self.isRussian ? "Загрузить плагин (.py)" : "Load Plugin (.py)" }
    public var pastePluginTitle: String { self.isRussian ? "Вставить плагин из буфера" : "Paste Plugin from Clipboard" }
    public var installedPluginsHeader: String { self.isRussian ? "УСТАНОВЛЕННЫЕ ПЛАГИНЫ" : "INSTALLED PLUGINS" }
    public var noPluginsTitle: String { self.isRussian ? "Нет установленных плагинов" : "No plugins installed" }
    public var pluginsFooter: String {
        self.isRussian
            ? "Плагины на Python имеют доступ к Telegram API, HTTP/WebSocket-запросам к внешним серверам, камере и хранилищу. Нажмите на плагин для просмотра логов, кода или удаления."
            : "Python plugins have full access to Telegram API, external HTTP/WebSocket servers, camera/media, and local storage. Tap a plugin to inspect logs, code, or delete it."
    }
    public var disguiseTitle: String { self.isRussian ? "Маскировка под Telegram" : "Disguise as Telegram" }
    public var disguiseFooter: String {
        self.isRussian
            ? "При включении иконка приложения на домашнем экране меняется на стандартную иконку Telegram. По умолчанию используется иконка KuniGram (персик на белом фоне). Примечание: iOS не позволяет динамически менять системное название приложения (CFBundleDisplayName) без пересборки."
            : "When enabled, the home screen app icon switches to the standard Telegram icon. By default, KuniGram uses the peach-on-white icon. Note: iOS does not allow changing CFBundleDisplayName on the home screen at runtime without rebuilding."
    }
    public var pluginDetailsTitle: String { self.isRussian ? "Плагин" : "Plugin" }
    public var pluginEnabledTitle: String { self.isRussian ? "Включён" : "Enabled" }
    public var pluginAuthorTitle: String { self.isRussian ? "Автор" : "Author" }
    public var pluginVersionTitle: String { self.isRussian ? "Версия" : "Version" }
    public var pluginRunTestTitle: String { self.isRussian ? "Перезапустить on_load()" : "Re-run on_load()" }
    public var pluginDeleteTitle: String { self.isRussian ? "Удалить плагин" : "Delete Plugin" }
    public var pluginLogsHeader: String { self.isRussian ? "ЛОГИ ВЫПОЛНЕНИЯ" : "EXECUTION LOGS" }
    public var pluginCodeHeader: String { self.isRussian ? "ИСХОДНЫЙ КОД" : "SOURCE CODE" }
    public var deleteConfirmTitle: String { self.isRussian ? "Удалить плагин?" : "Delete Plugin?" }
    public var cancelTitle: String { self.isRussian ? "Отмена" : "Cancel" }
    public var deleteTitle: String { self.isRussian ? "Удалить" : "Delete" }
    public var importedToast: String { self.isRussian ? "Плагин загружен" : "Plugin loaded" }
    public var clipboardEmptyToast: String { self.isRussian ? "Буфер обмена пуст" : "Clipboard is empty" }
    public var importErrorTitle: String { self.isRussian ? "Ошибка загрузки плагина" : "Failed to load plugin" }
}
