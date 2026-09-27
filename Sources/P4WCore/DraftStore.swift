import Foundation

/// Los borradores: lo que la persona escribió y todavía no mandó.
///
/// **Perder lo que alguien escribió es lo peor que puede hacer una interfaz**, y esto existe por un caso
/// concreto: a la esposa de Jorge se le borró lo escrito, y otra vez perdió el texto al cambiar de pestaña o
/// cerrar la app.
///
/// Tres decisiones, y las tres vienen de investigar cómo lo resuelven los clientes serios:
///
/// 1. **Uno por conversación**, con la conversación como clave. Antes había **un solo borrador para toda la
///    app**, lo que producía algo peor que perder el texto: cambiar de conversación **se lo llevaba a la
///    otra**, listo para mandarse al lugar equivocado.
/// 2. **En disco**, así sobrevive a cerrar la app.
/// 3. **Se borra recién cuando el envío está confirmado**, no cuando se aprieta Enter. Si el envío falla, el
///    texto tiene que seguir ahí.
public final class DraftStore: @unchecked Sendable {
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("P4W/drafts.json").path
    }

    private let path: String
    private let lock = NSRecursiveLock()
    private var drafts: [String: String] = [:]

    public init(path: String = DraftStore.defaultPath) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw SpacesStore.StoreError.read("no se pudieron leer los borradores")
        }
        // Un archivo ilegible no puede impedir arrancar: se empieza sin borradores y se sigue.
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        drafts = object.compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
    }

    /// El borrador de una conversación. Vacío si no hay.
    public func text(for key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return drafts[key] ?? ""
    }

    /// Guarda (o borra, si queda vacío). No escribe si no cambió nada: escribir en cada tecla castiga el
    /// disco sin razón.
    public func set(_ text: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = drafts[key] ?? ""
        guard text != previous else { return }
        if text.isEmpty { drafts.removeValue(forKey: key) } else { drafts[key] = text }
        try save()
    }

    /// Olvida el borrador de una conversación. Se llama cuando el envío está **confirmado**.
    public func remove(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard drafts[key] != nil else { return }
        drafts.removeValue(forKey: key)
        try save()
    }

    /// Cuántas conversaciones tienen borrador. Para poder verificarlo y para poder mostrarlo.
    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return drafts.count
    }

    public func keys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return drafts.keys.sorted()
    }

    private func save() throws {
        let snapshot = drafts
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: snapshot,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw SpacesStore.StoreError.write("no se pudieron serializar los borradores")
        }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Escritura atómica: si se corta a mitad, el archivo anterior queda entero en vez de a medias.
        let temporary = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: temporary))
    }
}
