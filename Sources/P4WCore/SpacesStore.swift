import Foundation

/// Un espacio de trabajo: agrupa conversaciones de un mismo contexto.
///
/// El vocabulario y las decisiones vienen de los dos proyectos que ya resolvieron esto
/// (`PLAN.md` §7.8): de **herdr** se toma la jerarquía con IDs cortos y estables que **no se
/// reutilizan**, y de **`pi-agent-board`** el vocabulario de estados.
///
/// Los IDs se guardan con un contador propio (`next_number`) en vez de derivarse de la cantidad de
/// espacios: si se borra el 2 y después se crea otro, no puede volver a llamarse `s2`, porque un ID
/// reutilizado rompería cualquier referencia vieja.
public struct Space: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: SpaceColor
    /// Las pestañas, en orden. Cada una es una conversación.
    public var tabs: [TabRef]

    public init(id: String, name: String, color: SpaceColor = .blue, tabs: [TabRef] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
    }

    /// Una pestaña apunta a un archivo de sesión de Pi. Guardar la **ruta** (y no solo el id) hace
    /// que el space siga siendo válido aunque el índice se reconstruya.
    public struct TabRef: Equatable, Sendable, Identifiable {
        public var sessionPath: String
        /// Perfil con el que se abre. Puede cambiar por pestaña (`PLAN.md` §6.1).
        public var profileName: String

        public var id: String { sessionPath }

        public init(sessionPath: String, profileName: String) {
            self.sessionPath = sessionPath
            self.profileName = profileName
        }
    }

    /// Nombres de color, no valores: así el tema claro y el oscuro funcionan solos.
    public enum SpaceColor: String, CaseIterable, Sendable {
        case blue, purple, green, orange, pink, teal, gray

        public var label: String {
            switch self {
            case .blue: return "azul"
            case .purple: return "violeta"
            case .green: return "verde"
            case .orange: return "naranja"
            case .pink: return "rosa"
            case .teal: return "turquesa"
            case .gray: return "gris"
            }
        }
    }
}

/// Los spaces guardados en disco.
///
/// El archivo es **versionado** y se escribe de forma **atómica**: se arma entero en un temporal y
/// después se reemplaza. Un corte de luz a mitad de escritura no puede dejar el archivo roto —y si
/// se rompiera, se pierde la organización, no las conversaciones (que viven en los `.jsonl` de Pi).
public final class SpacesStore: @unchecked Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case read(String)
        case write(String)

        public var description: String {
            switch self {
            case .read(let detail): return "No se pudieron leer los espacios: \(detail)"
            case .write(let detail): return "No se pudieron guardar los espacios: \(detail)"
            }
        }
    }

    /// Versión del archivo. Sube cuando cambia la forma; `migrate` aplica los pasos.
    public static let currentVersion = 1

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/.local/share").expandingTildeInPath)
        return base.appendingPathComponent("P4W/spaces.json").path
    }

    public let path: String
    private let lock = NSRecursiveLock()
    private var spaces: [Space] = []
    private var nextNumber = 1
    /// Conversaciones fijadas: nunca se reciclan, aunque no sean la visible.
    private var pinned: Set<String> = []
    /// Sugerencias de agrupado que la persona ya ignoró. Se recuerdan para no volver a proponerlas en
    /// cada arranque: una sugerencia que reaparece siempre es peor que no tener sugerencias.
    private var dismissedClusters: Set<String> = []
    /// Secciones del sidebar plegadas. **Un solo conjunto para todo el sidebar**, con una clave por
    /// sección: `sugerencias`, `espacios`, `historial`, `space:<id>`, `proyecto:<nombre>`.
    ///
    /// Vive acá y no en una preferencia porque es lo mismo que los tabs fijados: **el orden propio de la
    /// columna**. Y no en un `@State` de la vista, que era donde estaba y se perdía en cada arranque.
    private var collapsedSections: Set<String> = []

    public init(path: String = SpacesStore.defaultPath) throws {
        self.path = path
        try load()
    }

    // MARK: - Lectura

    public func all() -> [Space] {
        lock.lock(); defer { lock.unlock() }
        return spaces
    }

    public func space(withID id: String) -> Space? {
        lock.lock(); defer { lock.unlock() }
        return spaces.first { $0.id == id }
    }

    /// En qué space está una conversación, si está en alguno.
    public func spaceContaining(sessionPath: String) -> Space? {
        lock.lock(); defer { lock.unlock() }
        return spaces.first { $0.tabs.contains { $0.sessionPath == sessionPath } }
    }

    public func contains(sessionPath: String) -> Bool {
        spaceContaining(sessionPath: sessionPath) != nil
    }

    // MARK: - Escritura

    @discardableResult
    public func createSpace(name: String, color: Space.SpaceColor = .blue) throws -> Space {
        lock.lock(); defer { lock.unlock() }
        let space = Space(id: "s\(nextNumber)", name: name, color: color)
        nextNumber += 1
        spaces.append(space)
        try save()
        return space
    }

    public func renameSpace(id: String, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        try save()
    }

    public func setColor(_ color: Space.SpaceColor, forSpace id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].color = color
        try save()
    }

    /// Borra un space. **No toca las conversaciones**: los `.jsonl` siguen en el historial de Pi.
    public func deleteSpace(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        spaces.removeAll { $0.id == id }
        try save()
    }

    /// Mueve una conversación a un space (la saca de cualquier otro: una conversación vive en uno solo).
    public func move(sessionPath: String, profileName: String, toSpaceID id: String) throws {
        lock.lock(); defer { lock.unlock() }
        for index in spaces.indices {
            spaces[index].tabs.removeAll { $0.sessionPath == sessionPath }
        }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else {
            try save()
            return
        }
        spaces[index].tabs.append(Space.TabRef(sessionPath: sessionPath, profileName: profileName))
        try save()
    }

    /// Saca una conversación de todos los spaces. Es lo que se llama al mandarla a la papelera.
    public func removeFromSpaces(sessionPath: String) throws {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for index in spaces.indices where spaces[index].tabs.contains(where: { $0.sessionPath == sessionPath }) {
            spaces[index].tabs.removeAll { $0.sessionPath == sessionPath }
            changed = true
        }
        if changed { try save() }
    }

    public func dismissedClusterKeys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return dismissedClusters
    }

    public func dismissCluster(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        dismissedClusters.insert(key)
        try save()
    }

    public func forgetDismissedClusters() throws {
        lock.lock(); defer { lock.unlock() }
        guard !dismissedClusters.isEmpty else { return }
        dismissedClusters.removeAll()
        try save()
    }

    public func collapsedKeys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return collapsedSections
    }

    public func setCollapsed(_ collapsed: Bool, section key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if collapsed { collapsedSections.insert(key) } else { collapsedSections.remove(key) }
        try save()
    }

    public func pinnedPaths() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return pinned
    }

    public func setPinned(_ paths: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        guard pinned != paths else { return }
        pinned = paths
        try save()
    }

    /// Reordena los spaces según la lista de IDs. Es lo que hace el arrastre en el sidebar.
    /// Los IDs que no estén en la lista se conservan al final: nunca se pierde un space por un
    /// arrastre incompleto.
    public func reorderSpaces(ids: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let byID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        var reordered = ids.compactMap { byID[$0] }
        for space in spaces where !ids.contains(space.id) { reordered.append(space) }
        guard reordered != spaces else { return }
        spaces = reordered
        try save()
    }

    /// Reordena los tabs dentro de un space.
    public func reorderTabs(inSpaceID id: String, sessionPaths: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let tabs = spaces[index].tabs
        let byPath = Dictionary(uniqueKeysWithValues: tabs.map { ($0.sessionPath, $0) })
        var reordered = sessionPaths.compactMap { byPath[$0] }
        for tab in tabs where !sessionPaths.contains(tab.sessionPath) { reordered.append(tab) }
        guard reordered != tabs else { return }
        spaces[index].tabs = reordered
        try save()
    }

    /// Saca los tabs cuyos archivos ya no existen.
    ///
    /// Se le pasa el conjunto de rutas que **sí** existen en vez de mirar el disco: así la decisión de
    /// qué está vivo queda en un solo lugar (el índice) y esto se puede verificar sin tocar archivos.
    /// Devuelve cuántos sacó.
    /// Saca las pestañas cuyo archivo **ya no existe**, preguntándole al disco.
    ///
    /// Es distinto de podar contra "lo que el índice acaba de traer": esa lista puede venir parcial —o un
    /// archivo no se poder leer un instante— y entonces una conversación **saldría de su space por una
    /// ausencia momentánea**. Es lo que Jorge reportó: *"deben mantenerse en el space en que las dejo"*.
    ///
    /// La pregunta se recibe como función para poder verificarla **sin tocar archivos**.
    @discardableResult
    public func pruneTabs(exists: (String) -> Bool) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for index in spaces.indices {
            let before = spaces[index].tabs.count
            spaces[index].tabs.removeAll { !exists($0.sessionPath) }
            removed += before - spaces[index].tabs.count
        }
        if removed > 0 { try save() }
        return removed
    }

    @discardableResult
    public func pruneTabs(existingPaths: Set<String>) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for index in spaces.indices {
            let before = spaces[index].tabs.count
            spaces[index].tabs.removeAll { !existingPaths.contains($0.sessionPath) }
            removed += before - spaces[index].tabs.count
        }
        if removed > 0 { try save() }
        return removed
    }

    // MARK: - Persistencia

    private func load() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: path) else {
            spaces = []
            nextNumber = 1
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw StoreError.read("no se pudo abrir el archivo")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.read("el archivo no es JSON válido")
        }
        // Migración: un archivo sin `version` es de antes de que existiera el campo.
        let version = object["version"] as? Int ?? 0
        if version > Self.currentVersion {
            throw StoreError.read("el archivo es de una versión más nueva (\(version))")
        }
        nextNumber = object["next_number"] as? Int ?? 1
        pinned = Set(object["pinned"] as? [String] ?? [])
        dismissedClusters = Set(object["dismissed_clusters"] as? [String] ?? [])
        collapsedSections = Set(object["collapsed_sections"] as? [String] ?? [])
        let rawSpaces = object["spaces"] as? [[String: Any]] ?? []
        spaces = rawSpaces.compactMap { raw in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
            let color = Space.SpaceColor(rawValue: raw["color"] as? String ?? "") ?? .blue
            let tabs = (raw["tabs"] as? [[String: Any]] ?? []).compactMap { tab -> Space.TabRef? in
                guard let sessionPath = tab["session_path"] as? String else { return nil }
                return Space.TabRef(sessionPath: sessionPath,
                                    profileName: tab["profile"] as? String ?? "lean")
            }
            return Space(id: id, name: name, color: color, tabs: tabs)
        }
        // Un contador que quedó atrás no puede generar un ID ya usado.
        if let maxNumber = spaces.compactMap({ Int($0.id.dropFirst()) }).max(), maxNumber >= nextNumber {
            nextNumber = maxNumber + 1
        }
        // Si el archivo no tenía versión, se reescribe ya migrado.
        if version < Self.currentVersion { try saveLocked() }
    }

    public func save() throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked()
    }

    private func saveLocked() throws {
        let payload: [String: Any] = [
            "version": Self.currentVersion,
            "next_number": nextNumber,
            "pinned": pinned.sorted(),
            "dismissed_clusters": dismissedClusters.sorted(),
            "collapsed_sections": collapsedSections.sorted(),
            "spaces": spaces.map { space in
                [
                    "id": space.id,
                    "name": space.name,
                    "color": space.color.rawValue,
                    "tabs": space.tabs.map { ["session_path": $0.sessionPath, "profile": $0.profileName] },
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw StoreError.write("no se pudo serializar")
        }

        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Atómico: se arma en un temporal y recién después se reemplaza. Nunca queda a medias.
        let temporary = "\(path).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
            let destination = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(destination,
                                                          withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try FileManager.default.moveItem(atPath: temporary, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw StoreError.write(error.localizedDescription)
        }
    }
}
