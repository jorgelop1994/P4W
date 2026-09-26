import Foundation

/// Preferencias propias de P4W.
///
/// **No es configuración de Pi.** La de Pi vive en `~/.pi/agent/settings.json` y P4W la refleja
/// (decisión 2 del plan). Esto es otra cosa: la apariencia y el comportamiento de esta aplicación —
/// qué perfil se usa por defecto, y lo que se agregue después.
///
/// Se escribe de forma atómica, igual que los spaces: un corte a mitad no puede dejar el archivo roto,
/// y si se rompiera solo se pierden preferencias, nunca conversaciones.
public final class PreferencesStore: @unchecked Sendable {

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/.local/share").expandingTildeInPath)
        return base.appendingPathComponent("P4W/preferences.json").path
    }

    public enum Key: String {
        /// Clave del perfil que se usa al abrir una conversación.
        case defaultProfile = "default_profile"
        /// Si P4W le pide al modelo un nombre para cada grupo de conversaciones.
        ///
        /// **Apagado por defecto**, y ausente significa apagado: nombrar cuesta pedidos, y el agrupado
        /// tiene que servir sin gastar nada. Con esto apagado las etiquetas son las del grupo (sus
        /// términos), que no dependen de ningún modelo.
        case nameClustersWithModel = "name_clusters_with_model"
        /// Dónde vive el gato. Ausente = la ubicación recomendada.
        ///
        /// Que esté **ausente** es un dato: significa que la persona nunca lo movió, así que todavía
        /// conviene explicarle que se puede mover.
        case avatarPosition = "avatar_position"
        /// Si ya se descartó la explicación de que el gato se puede mover de lugar.
        case avatarHintDismissed = "avatar_hint_dismissed"
        /// Cuánto mide el gato. Ausente = el tamaño recomendado.
        case avatarSize = "avatar_size"
        /// Si el ícono del Dock muestra el estado. Ausente = encendido.
        case dockIconLive = "dock_icon_live"
        /// Avisos de dependencias que ya se descartaron (los opcionales y los recomendados).
        case dismissedDependencies = "dismissed_dependencies"
        /// La versión de la que ya se avisó y se descartó. Se guarda la **versión**, no un "no mostrar
        /// más", porque descartar la 0.2.0 no puede silenciar la 0.3.0.
        case dismissedUpdateVersion = "dismissed_update_version"
        /// Cuándo se consultó por última vez, para no golpear la API: una vez por día alcanza.
        case lastUpdateCheck = "last_update_check"
    }

    private let path: String
    private let lock = NSRecursiveLock()
    private var values: [String: Any] = [:]

    public init(path: String = PreferencesStore.defaultPath) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw SpacesStore.StoreError.read("no se pudo abrir las preferencias")
        }
        // Un archivo ilegible no puede impedir arrancar: se empieza de cero y se avisa por el valor.
        values = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func string(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key.rawValue] as? String
    }

    public func set(_ value: String?, for key: Key) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            values[key.rawValue] = value
        } else {
            values.removeValue(forKey: key.rawValue)
        }
        try save()
    }

    private func save() throws {
        guard let data = try? JSONSerialization.data(
            withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw SpacesStore.StoreError.write("no se pudieron serializar las preferencias")
        }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = "\(path).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                          withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try FileManager.default.moveItem(atPath: temporary, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw SpacesStore.StoreError.write(error.localizedDescription)
        }
    }
}
