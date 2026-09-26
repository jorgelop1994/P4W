import Foundation

/// Resumen de una conversación guardada en disco.
///
/// Fase 2 lee **solo la cabecera y la cola** de cada `.jsonl`: son 2 lecturas por archivo en vez
/// de parsear 461 sesiones completas (algunas de 6 MB). El índice completo con búsqueda llega
/// en Fase 3.
public struct SessionSummary: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let project: String
    public let cwd: String?
    public let modified: Date
    public let sizeBytes: Int64
    /// Mutable a propósito: el indexador lo completa cuando el nombre aparece en el cuerpo del
    /// archivo y no en la cola que se leyó al principio.
    public var name: String?
    public var preview: String
    public var previewAuthor: String?

    /// Público a propósito: las verificaciones arman resúmenes a mano para probar el índice y el
    /// agrupado sin depender de archivos reales.
    public init(id: String, path: String, project: String, cwd: String?, modified: Date,
                sizeBytes: Int64, name: String?, preview: String, previewAuthor: String?) {
        self.id = id
        self.path = path
        self.project = project
        self.cwd = cwd
        self.modified = modified
        self.sizeBytes = sizeBytes
        self.name = name
        self.preview = preview
        self.previewAuthor = previewAuthor
    }

    /// Pi **se niega a abrir** una sesión cuya carpeta de trabajo guardada ya no existe. Sin esto,
    /// la interfaz intentaba abrirla y el usuario recibía un timeout en vez del motivo.
    public var cwdIsAvailable: Bool {
        guard let cwd, !cwd.isEmpty else { return true }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return project
    }

    public var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modified, relativeTo: Date())
    }

    /// Cuánto ocupa en disco, para que el peso de una sesión larga sea visible.
    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum SessionCatalog {

    public static var defaultRoot: String {
        NSString(string: "~/.pi/agent/sessions").expandingTildeInPath
    }

    /// Manda una conversación a la **papelera**, nunca la borra.
    ///
    /// `trashItem` es la única forma aceptable: deja la recuperación en manos del sistema, que es
    /// lo que cualquiera espera cuando borra algo. Un `removeItem` acá sería irreversible.
    public static func moveToTrash(path: String) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
        return (trashed as URL?) ?? URL(fileURLWithPath: path)
    }

    /// Lo que se puede saber de un archivo **sin abrirlo**: ruta, proyecto, fecha y tamaño.
    /// Es la base del indexado incremental: comparar esto contra lo guardado decide si hay que
    /// abrir el archivo o no. Abrir es la parte cara; `stat` no.
    public struct FileEntry: Sendable {
        public let path: String
        public let project: String
        public let modified: Date
        public let sizeBytes: Int64

        /// Huella para detectar cambios sin leer el contenido.
        public var fingerprint: String { "\(Int64(modified.timeIntervalSince1970)):\(sizeBytes)" }
    }

    /// Recorre el directorio de sesiones haciendo **solo `stat`** por archivo (sin leer nada).
    public static func scan(root: String = defaultRoot) -> [FileEntry] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(atPath: root) else { return [] }
        var entries: [FileEntry] = []
        for project in projects where !project.hasPrefix(".") {
            let directory = "\(root)/\(project)"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let files = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = "\(directory)/\(file)"
                guard let attributes = try? manager.attributesOfItem(atPath: path),
                      let size = attributes[.size] as? Int64 else { continue }
                entries.append(FileEntry(
                    path: path,
                    project: project,
                    modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
                    sizeBytes: size
                ))
            }
        }
        return entries
    }

    /// Recorre el directorio de sesiones y devuelve los resúmenes, más recientes primero.
    /// Sin tope por proyecto: devolver 60 de 400 sin decirlo era una mentira silenciosa. El
    /// índice es el camino normal; esto es el respaldo cuando el índice no está disponible.
    public static func load(root: String = defaultRoot,
                            limitPerProject: Int = Int.max) -> [SessionSummary] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(atPath: root) else { return [] }

        var results: [SessionSummary] = []
        for project in projects where !project.hasPrefix(".") {
            let directory = "\(root)/\(project)"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let files = try? manager.contentsOfDirectory(atPath: directory) else { continue }

            let jsonl = files.filter { $0.hasSuffix(".jsonl") }
            let sorted = jsonl.sorted { $0 > $1 }   // el nombre arranca con el timestamp ISO
            for file in sorted.prefix(limitPerProject == Int.max ? sorted.count : limitPerProject) {
                let path = "\(directory)/\(file)"
                if let summary = summarize(path: path, project: project) {
                    results.append(summary)
                }
            }
        }
        return results.sorted { $0.modified > $1.modified }
    }

    /// Lee la cabecera y la cola de un archivo de sesión.
    public static func summarize(path: String, project: String) -> SessionSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return nil }
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Cabecera: la primera línea trae id, cwd y timestamp.
        var id = (path as NSString).lastPathComponent
        var cwd: String?
        if let headerData = try? handle.read(upToCount: 8192) {
            for line in headerData.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                if object["type"] as? String == "session" {
                    id = object["id"] as? String ?? id
                    cwd = object["cwd"] as? String
                }
                break
            }
        }

        // Cola: nombre visible y último mensaje, sin parsear el archivo entero.
        var name: String?
        var preview = ""
        var previewAuthor: String?
        let tailBytes = 65_536
        if size > Int64(tailBytes) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(tailBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        if let tailData = try? handle.readToEnd() {
            var lines = tailData.split(separator: 0x0A)
            if size > Int64(tailBytes), !lines.isEmpty { lines.removeFirst() }  // línea partida
            for line in lines.reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                let type = object["type"] as? String
                if type == "session_info", name == nil {
                    name = object["name"] as? String
                }
                if type == "message", preview.isEmpty {
                    guard let message = object["message"] as? [String: Any],
                          let role = message["role"] as? String, role != "system" else { continue }
                    let blocks = message["content"] as? [[String: Any]] ?? []
                    let text = blocks.compactMap { block -> String? in
                        block["type"] as? String == "text" ? block["text"] as? String : nil
                    }.joined()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    preview = String(trimmed.replacingOccurrences(of: "\n", with: " ").prefix(160))
                    previewAuthor = role
                }
                if name != nil, !preview.isEmpty { break }
            }
        }

        return SessionSummary(
            id: id,
            path: path,
            project: project,
            cwd: cwd,
            modified: modified,
            sizeBytes: size,
            name: name,
            preview: preview,
            previewAuthor: previewAuthor
        )
    }
}
