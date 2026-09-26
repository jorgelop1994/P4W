import Foundation

/// Lee y escribe la configuración de Pi: `~/.pi/agent/settings.json`.
///
/// Reglas que sigue, todas nacidas del plan:
///
/// - **P4W no tiene configuración propia.** Esta es la de Pi, editada desde acá. Nada duplicado.
/// - **Se relee antes de escribir** y se avisa si el archivo cambió mientras la ventana estaba
///   abierta: Pi también lo escribe, y sobrescribir a ciegas perdería un cambio suyo.
/// - **Se hace copia de seguridad la primera vez** que se escribe, para que un error sea recuperable.
/// - **Candado**: no se escribe si hay instancias activas. Pi lee la configuración al arrancar y
///   escribir con procesos vivos es pedir una condición de carrera.
public final class PiSettingsStore: @unchecked Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case locked(Int)
        case read(String)
        case write(String)

        public var description: String {
            switch self {
            case .locked(let count):
                return "Hay \(count) conversación(es) activa(s). Cerrá las conversaciones o esperá a que se liberen."
            case .read(let detail): return "No se pudo leer la configuración: \(detail)"
            case .write(let detail): return "No se pudo escribir la configuración: \(detail)"
            }
        }
    }

    public static var defaultPath: String {
        NSString(string: "~/.pi/agent/settings.json").expandingTildeInPath
    }

    public let path: String
    /// Recursivo a propósito: `apply` toma el lock y adentro llama a `changedOnDisk()`, que también
    /// lo toma. Con un `NSLock` común eso era un **deadlock** — y se descubrió porque el
    /// autodiagnóstico se quedó colgado justo en esa línea.
    private let lock = NSRecursiveLock()
    private var loaded: [String: Any] = [:]
    /// Fecha y tamaño del archivo cuando se leyó, para detectar que alguien más lo cambió.
    private var loadedFingerprint: String = ""

    public init(path: String = PiSettingsStore.defaultPath) throws {
        self.path = path
        try reload()
    }

    public func reload() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: path) else {
            loaded = [:]
            loadedFingerprint = ""
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw StoreError.read("no se pudo abrir el archivo")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.read("el archivo no es JSON válido")
        }
        loaded = object
        loadedFingerprint = fingerprint()
    }

    /// ¿Cambió el archivo desde que se leyó? Significa que Pi escribió mientras tanto.
    public func changedOnDisk() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !loadedFingerprint.isEmpty && fingerprint() != loadedFingerprint
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    // MARK: Leer

    /// Valor de una clave con puntos (`compaction.enabled`).
    public func value(for key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        var current: Any? = loaded
        for part in key.split(separator: ".") {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[String(part)]
        }
        return current
    }

    /// Valor listo para mostrar: los booleanos dicen sí/no, las listas se muestran en líneas.
    public func displayValue(for key: String) -> String {
        guard let value = value(for: key) else { return "" }
        switch value {
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        case let text as String: return text
        case let list as [Any]: return list.map { "\($0)" }.joined(separator: "\n")
        case is [String: Any]: return "objeto"
        default: return "\(value)"
        }
    }

    // MARK: Escribir

    /// Aplica los cambios de una vez. `activeInstances` es el candado: con conversaciones activas no
    /// se escribe.
    ///
    /// Los cambios son `[clave: valor?]`; `nil` **quita** la clave, que es como Pi vuelve al valor por
    /// defecto. Se escribe todo junto para que el archivo quede consistente.
    public func apply(_ changes: [String: Any?], activeInstances: Int) throws {
        guard activeInstances == 0 else { throw StoreError.locked(activeInstances) }
        lock.lock()
        defer { lock.unlock() }

        // Releer: si Pi escribió mientras la ventana estaba abierta, lo nuevo manda y P4W avisa.
        let before = loaded
        let externalChange = changedOnDisk()
        if externalChange {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let fresh = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StoreError.read("el archivo cambió y no se pudo releer")
            }
            loaded = fresh
        }

        var updated = loaded
        for (key, value) in changes {
            if let value {
                Self.set(value, at: key, in: &updated)
            } else {
                Self.remove(key, from: &updated)
            }
        }

        // Copia de seguridad solo la primera vez: no se llena el directorio de copias.
        let backup = "\(path).p4w-backup"
        if FileManager.default.fileExists(atPath: path),
           !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            loaded = before
            throw StoreError.write("no se pudo serializar")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            loaded = before
            throw StoreError.write(error.localizedDescription)
        }
        loaded = updated
        loadedFingerprint = fingerprint()
    }

    /// Aplica el valor en la ruta, creando los objetos intermedios que falten.
    static func set(_ value: Any, at key: String, in root: inout [String: Any]) {
        let parts = key.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 {
            root[first] = value
            return
        }
        var nested = (root[first] as? [String: Any]) ?? [:]
        Self.setNested(value, parts: Array(parts.dropFirst()), in: &nested)
        root[first] = nested
    }

    private static func setNested(_ value: Any, parts: [String], in dictionary: inout [String: Any]) {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dictionary[first] = value
            return
        }
        var nested = (dictionary[first] as? [String: Any]) ?? [:]
        setNested(value, parts: Array(parts.dropFirst()), in: &nested)
        dictionary[first] = nested
    }

    static func remove(_ key: String, from root: inout [String: Any]) {
        let parts = key.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        guard parts.count > 1 else {
            root.removeValue(forKey: first)
            return
        }
        guard var nested = root[first] as? [String: Any] else { return }
        removeNested(parts: Array(parts.dropFirst()), in: &nested)
        // Un objeto que queda vacío se saca: así el archivo no acumula cáscaras.
        if nested.isEmpty { root.removeValue(forKey: first) } else { root[first] = nested }
    }

    private static func removeNested(parts: [String], in dictionary: inout [String: Any]) {
        guard let first = parts.first else { return }
        guard parts.count > 1 else {
            dictionary.removeValue(forKey: first)
            return
        }
        guard var nested = dictionary[first] as? [String: Any] else { return }
        removeNested(parts: Array(parts.dropFirst()), in: &nested)
        if nested.isEmpty { dictionary.removeValue(forKey: first) } else { dictionary[first] = nested }
    }

    private func fingerprint() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return "" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int64(modified)):\(size)"
    }
}
