import Foundation
import AccountContext

public struct KuniGramPlugin: Equatable, Codable {
    public let id: String
    public var name: String
    public var author: String
    public var version: String
    public var description: String
    public var fileName: String
    public var isEnabled: Bool
    public var lastError: String?

    public init(
        id: String,
        name: String,
        author: String,
        version: String,
        description: String,
        fileName: String,
        isEnabled: Bool,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.fileName = fileName
        self.isEnabled = isEnabled
        self.lastError = lastError
    }
}

public final class KuniGramPluginEngine {
    public static let shared = KuniGramPluginEngine()
    public static let pluginsDidChangeNotification = Notification.Name("KuniGramPluginsDidChangeNotification")

    public private(set) var plugins: [KuniGramPlugin] = []

    private let queue = DispatchQueue(label: "com.kunigram.plugin.engine")
    private let pluginsDirURL: URL
    private let manifestURL: URL
    private var logsByPluginId: [String: [String]] = [:]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let base = docs.appendingPathComponent("KuniGram", isDirectory: true)
        let dir = base.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.pluginsDirURL = dir
        self.manifestURL = dir.appendingPathComponent("plugins.json")
        self.loadManifest()
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: self.manifestURL),
              let decoded = try? JSONDecoder().decode([KuniGramPlugin].self, from: data) else {
            self.plugins = []
            return
        }
        self.plugins = decoded
    }

    private func saveManifestLocked() {
        guard let data = try? JSONEncoder().encode(self.plugins) else { return }
        try? data.write(to: self.manifestURL, options: .atomic)
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.pluginsDidChangeNotification, object: nil)
        }
    }

    private func scriptURL(for pluginId: String) -> URL {
        let safe = pluginId.replacingOccurrences(of: "/", with: "_")
        return self.pluginsDirURL.appendingPathComponent("\(safe).py")
    }

    @discardableResult
    public func importPlugin(from url: URL, context: AccountContext) throws -> KuniGramPlugin {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let code = try String(contentsOf: url, encoding: .utf8)
        return try self.importPlugin(code: code, fileName: url.lastPathComponent, context: context)
    }

    @discardableResult
    public func importPlugin(code: String, fileName: String, context: AccountContext) throws -> KuniGramPlugin {
        let meta = Self.parseMetadata(from: code, fallbackFileName: fileName)
        let id = meta.id
        let plugin = KuniGramPlugin(
            id: id,
            name: meta.name,
            author: meta.author,
            version: meta.version,
            description: meta.description,
            fileName: fileName,
            isEnabled: true,
            lastError: nil
        )

        let destURL = self.scriptURL(for: id)
        try code.write(to: destURL, atomically: true, encoding: .utf8)

        self.queue.sync {
            if let idx = self.plugins.firstIndex(where: { $0.id == id }) {
                self.plugins[idx] = plugin
            } else {
                self.plugins.append(plugin)
            }
            self.logsByPluginId[id] = []
            self.saveManifestLocked()
        }

        self.notifyChanged()
        self.runPlugin(id: id, code: code, context: context)
        return plugin
    }

    public func setPluginEnabled(id: String, enabled: Bool, context: AccountContext) {
        var codeToRun: String?
        self.queue.sync {
            guard let idx = self.plugins.firstIndex(where: { $0.id == id }) else { return }
            self.plugins[idx].isEnabled = enabled
            if enabled {
                self.plugins[idx].lastError = nil
                codeToRun = try? String(contentsOf: self.scriptURL(for: id), encoding: .utf8)
            }
            self.saveManifestLocked()
        }
        self.notifyChanged()
        if let code = codeToRun {
            self.runPlugin(id: id, code: code, context: context)
        }
    }

    public func rerunOnLoad(id: String, context: AccountContext) {
        let code = self.sourceCode(for: id)
        guard !code.isEmpty else { return }
        self.queue.sync {
            if let idx = self.plugins.firstIndex(where: { $0.id == id }) {
                self.plugins[idx].lastError = nil
                self.saveManifestLocked()
            }
        }
        self.notifyChanged()
        self.runPlugin(id: id, code: code, context: context)
    }

    public func deletePlugin(id: String) {
        self.queue.sync {
            self.plugins.removeAll(where: { $0.id == id })
            self.logsByPluginId.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: self.scriptURL(for: id))
            self.saveManifestLocked()
        }
        self.notifyChanged()
    }

    public func logs(for pluginId: String) -> [String] {
        return self.queue.sync {
            return self.logsByPluginId[pluginId] ?? []
        }
    }

    public func sourceCode(for pluginId: String) -> String {
        return (try? String(contentsOf: self.scriptURL(for: pluginId), encoding: .utf8)) ?? ""
    }

    private func appendLog(pluginId: String, message: String) {
        self.queue.sync {
            var arr = self.logsByPluginId[pluginId] ?? []
            arr.append(message)
            if arr.count > 200 {
                arr.removeFirst(arr.count - 200)
            }
            self.logsByPluginId[pluginId] = arr
        }
    }

    private func runPlugin(id: String, code: String, context: AccountContext) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let logHandler: (String) -> Void = { [weak self] msg in
                self?.appendLog(pluginId: id, message: msg)
            }
            let api = KuniGramPluginAPI(pluginId: id, context: context, logHandler: logHandler)
            let interpreter = KuniPyInterpreter(apiObject: api.buildAPIObject(), logHandler: logHandler)
            interpreter.registerModule(name: "kunigram", value: api.buildAPIObject())
            interpreter.registerModule(name: "requests", value: api.buildNetworkModule())
            do {
                try interpreter.execute(source: code)
                if interpreter.hasFunction("on_plugin_load") {
                    _ = try interpreter.callFunction("on_plugin_load")
                }
                self.queue.sync {
                    if let idx = self.plugins.firstIndex(where: { $0.id == id }) {
                        self.plugins[idx].lastError = nil
                        self.saveManifestLocked()
                    }
                }
            } catch {
                let errMsg = error.localizedDescription
                self.appendLog(pluginId: id, message: "[ERROR] \(errMsg)")
                self.queue.sync {
                    if let idx = self.plugins.firstIndex(where: { $0.id == id }) {
                        self.plugins[idx].lastError = errMsg
                        self.saveManifestLocked()
                    }
                }
            }
            self.notifyChanged()
        }
    }

    private static func parseMetadata(from code: String, fallbackFileName: String) -> (id: String, name: String, author: String, version: String, description: String) {
        let baseName = (fallbackFileName as NSString).deletingPathExtension
        var id = ""
        var name = ""
        var author = ""
        var version = ""
        var description = ""

        let lines = code.components(separatedBy: .newlines).prefix(60)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let val = extractAssign(line, keys: ["__id__", "PLUGIN_ID"]) { id = val }
            if let val = extractAssign(line, keys: ["__name__", "PLUGIN_NAME"]) { name = val }
            if let val = extractAssign(line, keys: ["__author__", "PLUGIN_AUTHOR"]) { author = val }
            if let val = extractAssign(line, keys: ["__version__", "PLUGIN_VERSION"]) { version = val }
            if let val = extractAssign(line, keys: ["__description__", "PLUGIN_DESCRIPTION"]) { description = val }
        }

        if name.isEmpty { name = baseName.isEmpty ? "Plugin" : baseName }
        if id.isEmpty {
            let sanitized = name.lowercased().replacingOccurrences(of: " ", with: "_")
            id = sanitized.isEmpty ? UUID().uuidString : sanitized
        }
        if author.isEmpty { author = "Unknown" }
        if version.isEmpty { version = "1.0" }
        return (id, name, author, version, description)
    }

    private static func extractAssign(_ line: String, keys: [String]) -> String? {
        for key in keys {
            if line.hasPrefix(key) {
                let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("=") {
                    var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    return value
                }
            }
        }
        return nil
    }
}
