import Foundation
import SQLite3

/// Índice local de conversaciones sobre SQLite.
///
/// Usa el SQLite del sistema (probado en Fase 3.1: 3.54.0, con FTS5 y el tokenizador
/// `unicode61 remove_diacritics 2`, que hace que "transcripcion" encuentre "transcripción").
///
/// **P4W nunca escribe los `.jsonl`** (invariante 1). Este archivo es propio de P4W y se puede borrar
/// sin consecuencias: se reconstruye.
public final class SessionIndex: @unchecked Sendable {

    public enum IndexError: Error, CustomStringConvertible {
        case open(String)
        case statement(String)
        case step(String)

        public var description: String {
            switch self {
            case .open(let detail): return "No se pudo abrir el índice: \(detail)"
            case .statement(let detail): return "Sentencia inválida: \(detail)"
            case .step(let detail): return "Error al ejecutar: \(detail)"
            }
        }
    }

    /// Versión del esquema. Sube cuando cambia la forma de las tablas; `migrate` aplica los pasos.
    public static let schemaVersion: Int32 = 4

    /// Tope del archivo WAL después de consolidar. 8 MB es holgado para indexar por lotes.
    public static let walSizeLimit = 8 * 1024 * 1024

    /// Versión del **contenido** del texto buscable, separada de la del esquema.
    ///
    /// Sube cuando cambia *qué* se deriva del archivo. Como eso no se puede detectar mirando el
    /// archivo —el archivo no cambió—, se guarda por sesión: así la migración reindexa una sola vez y
    /// las corridas siguientes vuelven a ser incrementales.
    ///
    /// - v2: de la vista previa a los mensajes completos.
    /// - v3: además la **firma temática**, que se calcula al indexar porque el texto ya está en la mano.
    ///
    /// **Sin este salto, las conversaciones viejas quedarían sin firma**: el indexador solo la guarda
    /// para lo que re-indexa, y en un arranque normal no re-indexa nada. Se descubrió verificando la app
    /// de punta a punta: calculaba **un solo** grupo sobre 470 conversaciones.
    public static let textVersion: Int32 = 3

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/.local/share").expandingTildeInPath)
        return base.appendingPathComponent("P4W/index.db").path
    }

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Profundidad de transacción. Escribir 467 sesiones abriendo y cerrando una transacción por
    /// cada una costaba 18,45 s (medido): el costo estaba en los commits, no en el trabajo. Con una
    /// sola transacción para todo el lote, el mismo trabajo baja a una fracción.
    private var transactionDepth = 0
    public let path: String

    public init(path: String = SessionIndex.defaultPath) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sin detalle"
            sqlite3_close(database)
            throw IndexError.open(detail)
        }
        handle = database
        // WAL: deja leer mientras se escribe, que es lo que pasa cuando la UI busca mientras indexa.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        // El WAL crecía sin límite: 257 MB medidos. Dos causas, las dos reales — nunca se
        // consolidaba (la app se mata con `pkill` y SQLite no llega a hacer su cierre limpio) y no
        // había tope. Con el chequeo explícito después de cada lote (ver `checkpoint`) y un límite
        // duro, el archivo queda en unos pocos MB.
        try exec("PRAGMA journal_size_limit = \(Self.walSizeLimit);")
        try exec("PRAGMA wal_autocheckpoint = 0;")
        try migrate()
    }

    deinit { close() }

    public func close() {
        checkpoint()
        lock.lock()
        defer { lock.unlock() }
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    // MARK: - Esquema

    private func migrate() throws {
        let current = try userVersion()
        guard current < Self.schemaVersion else { return }

        if current < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id            TEXT PRIMARY KEY,
                path          TEXT NOT NULL UNIQUE,
                cwd           TEXT,
                project       TEXT NOT NULL,
                name          TEXT,
                modified      REAL NOT NULL,
                size          INTEGER NOT NULL,
                indexed_at    REAL NOT NULL,
                text_version  INTEGER NOT NULL DEFAULT \(SessionIndex.textVersion)
            );
            """)
            try exec("CREATE INDEX IF NOT EXISTS sessions_modified ON sessions(modified DESC);")
            try exec("CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project);")
            // Búsqueda de texto completo. `session_id` sin indexar: se filtra, no se busca por él.
            try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                session_id UNINDEXED,
                path       UNINDEXED,
                role       UNINDEXED,
                body,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
        }

        if current < 3 {
            // v3: los grupos por tema y lo necesario para asignar una conversación nueva **sin**
            // re-agrupar todo. Eso último exige guardar el IDF del corpus: sin él, la firma de una
            // conversación nueva no sería comparable con los centroides guardados.
            try exec("""
            CREATE TABLE IF NOT EXISTS clusters (
                id          INTEGER PRIMARY KEY,
                top_terms   TEXT NOT NULL,
                size        INTEGER NOT NULL,
                centroid    TEXT NOT NULL,
                threshold   REAL NOT NULL,
                computed_at REAL NOT NULL
            );
            """)
            try exec("""
            CREATE TABLE IF NOT EXISTS corpus_terms (
                term TEXT PRIMARY KEY,
                df   INTEGER NOT NULL
            );
            """)
            try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        }
        if current < 4 {
            // v4: los nombres que puso el modelo. Se guardan **por clave de grupo** (sus términos
            // ordenados) para no volver a pedir el mismo nombre: cada pedido se paga.
            try exec("""
            CREATE TABLE IF NOT EXISTS cluster_names (
                key     TEXT PRIMARY KEY,
                name    TEXT NOT NULL,
                made_at REAL NOT NULL
            );
            """)
        }
        if try !hasColumn("sessions", "cluster_id") {
            try exec("ALTER TABLE sessions ADD COLUMN cluster_id INTEGER;")
        }
        if try !hasColumn("sessions", "signature") {
            try exec("ALTER TABLE sessions ADD COLUMN signature TEXT;")
        }

        // La columna se agrega si falta, sin importar por qué camino se llegó: una base nueva ya
        // la trae del CREATE, y una que venía de v1 la recibe acá. Preguntar en vez de suponer.
        if try !hasColumn("sessions", "text_version") {
            try exec("ALTER TABLE sessions ADD COLUMN text_version INTEGER NOT NULL DEFAULT 1;")
        }

        try setUserVersion(Self.schemaVersion)
    }

    /// ¿La tabla ya tiene esa columna? Evita depender de la versión para decidir el ALTER.
    private func hasColumn(_ table: String, _ column: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { statement.finalize() }
        while try statement.step() {
            if statement.string(1) == column { return true }
        }
        return false
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        return statement.int32(0)
    }

    private func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    // MARK: - Indexado

    /// Resultado de una corrida del indexador. Se devuelve para poder mostrarlo y medirlo.
    public struct Stats: Sendable {
        public var scanned = 0
        public var inserted = 0
        public var updated = 0
        public var unchanged = 0
        public var elapsed: TimeInterval = 0
        public var total: Int = 0

        /// El tiempo se reporta en ms cuando es chico: decir "0.00 s" esconde que algo pasó.
        public var elapsedLabel: String {
            elapsed < 1 ? String(format: "%.0f ms", elapsed * 1000)
                        : String(format: "%.2f s", elapsed)
        }

        public var summary: String {
            "\(scanned) leídas · \(inserted) nuevas · \(updated) actualizadas · "
                + "\(unchanged) sin cambios · \(total) en el índice · \(elapsedLabel)"
        }
    }

    /// Indexa el catálogo completo. En 3.1 es una pasada completa; el salto a incremental por
    /// `mtime`+tamaño es el paso 3.2.
    @discardableResult
    public func index(_ sessions: [SessionSummary]) throws -> Stats {
        let started = Date()
        var stats = Stats()

        guard handle != nil else { throw IndexError.open("índice cerrado") }
        try inTransaction {
            let statement = try prepare("""
            INSERT INTO sessions (id, path, cwd, project, name, modified, size, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                id = excluded.id, cwd = excluded.cwd, project = excluded.project,
                name = excluded.name, modified = excluded.modified, size = excluded.size,
                indexed_at = excluded.indexed_at;
            -- Ojo: `text_version` NO se toca acá. Esta tabla guarda metadatos; la versión del texto
            -- la maneja `replaceText`, que es quien realmente escribe el contenido buscable. Marcarla
            -- desde acá dejaría sesiones diciendo "texto al día" con el texto viejo.
            """)
            defer { statement.finalize() }

            let known = try existingFingerprints()

            for session in sessions {
                stats.scanned += 1
                let fingerprint = "\(Int64(session.modified.timeIntervalSince1970)):\(session.sizeBytes)"
                if let previous = known[session.path] {
                    if previous == fingerprint {
                        stats.unchanged += 1
                        continue
                    }
                    stats.updated += 1
                } else {
                    stats.inserted += 1
                }

                try statement.reset()
                try statement.bind(1, session.id)
                try statement.bind(2, session.path)
                try statement.bind(3, session.cwd)
                try statement.bind(4, session.project)
                try statement.bind(5, session.name)
                try statement.bind(6, session.modified.timeIntervalSince1970)
                try statement.bind(7, session.sizeBytes)
                try statement.bind(8, Date().timeIntervalSince1970)
                try statement.run()
            }
        }

        try indexSearchableText(sessions)
        stats.elapsed = Date().timeIntervalSince(started)
        stats.total = try count()
        return stats
    }

    /// Huella por ruta para saber si una sesión cambió sin volver a leerla entera.
    private func existingFingerprints() throws -> [String: String] {
        let statement = try prepare("SELECT path, modified, size FROM sessions;")
        defer { statement.finalize() }
        var result: [String: String] = [:]
        while try statement.step() {
            let path = statement.string(0) ?? ""
            let modified = Int64(statement.double(1))
            let size = Int64(statement.double(2))
            result[path] = "\(modified):\(size)"
        }
        return result
    }

    /// Una fila de texto buscable: el rol y el contenido.
    public struct TextRow: Sendable {
        public let role: String
        public let body: String
        public init(role: String, body: String) {
            self.role = role
            self.body = body
        }
    }

    /// Sesiones cuyo texto buscable quedó en una versión vieja y hay que reindexar.
    public func pathsNeedingText() throws -> Set<String> {
        let statement = try prepare("SELECT path FROM sessions WHERE text_version < ?;")
        defer { statement.finalize() }
        try statement.bind(1, Int64(Self.textVersion))
        var result: Set<String> = []
        while try statement.step() {
            if let path = statement.string(0) { result.insert(path) }
        }
        return result
    }

    /// Reemplaza el texto buscable de una sesión por sus mensajes, y la marca como al día.
    /// Las dos cosas van en la misma transacción: si queda a medias, la sesión se reindexaría sola.
    public func replaceText(sessionID: String, path: String, rows: [TextRow]) throws {
        let deleteStatement = try prepare("DELETE FROM messages_fts WHERE session_id = ?;")
        defer { deleteStatement.finalize() }
        let insertStatement = try prepare("""
        INSERT INTO messages_fts (session_id, path, role, body) VALUES (?, ?, ?, ?);
        """)
        defer { insertStatement.finalize() }
        let markStatement = try prepare("UPDATE sessions SET text_version = ? WHERE path = ?;")
        defer { markStatement.finalize() }

        try beginTransaction()
        try deleteStatement.bind(1, sessionID)
        try deleteStatement.run()

        for row in rows {
            let body = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            try insertStatement.reset()
            try insertStatement.bind(1, sessionID)
            try insertStatement.bind(2, path)
            try insertStatement.bind(3, row.role)
            try insertStatement.bind(4, body)
            try insertStatement.run()
        }

        try markStatement.bind(1, Int64(Self.textVersion))
        try markStatement.bind(2, path)
        try markStatement.run()
        try commitTransaction()
    }

    /// Actualiza el nombre de una sesión sin tocar el resto de la fila.
    public func setName(_ name: String?, path: String) throws {
        let statement = try prepare("UPDATE sessions SET name = ? WHERE path = ?;")
        defer { statement.finalize() }
        try statement.bind(1, name)
        try statement.bind(2, path)
        try statement.run()
    }

    /// Marca sesiones con una versión de texto concreta. Sirve para probar el camino de migración.
    public func markTextVersion(paths: [String], version: Int32) throws {
        guard !paths.isEmpty else { return }
        let statement = try prepare("UPDATE sessions SET text_version = ? WHERE path = ?;")
        defer { statement.finalize() }
        try inTransaction {
            for path in paths {
                try statement.reset()
                try statement.bind(1, Int64(version))
                try statement.bind(2, path)
                try statement.run()
            }
        }
    }

    /// Marca sesiones como que su texto ya está en la versión actual.
    public func markTextCurrent(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let statement = try prepare("UPDATE sessions SET text_version = ? WHERE path = ?;")
        defer { statement.finalize() }
        try beginTransaction()
        for path in paths {
            try statement.reset()
            try statement.bind(1, Int64(Self.textVersion))
            try statement.bind(2, path)
            try statement.run()
        }
        try commitTransaction()
    }

    /// Reemplaza el texto buscable de **esas** sesiones, sin tocar el de las demás.
    ///
    /// En 3.1 esto borraba y reinsertaba todo el FTS en cada corrida. Con indexado incremental eso
    /// dejaba de tener sentido: solo hay que reescribir lo que cambió.
    private func indexSearchableText(_ sessions: [SessionSummary]) throws {
        guard !sessions.isEmpty else { return }
        let deleteStatement = try prepare("DELETE FROM messages_fts WHERE session_id = ?;")
        defer { deleteStatement.finalize() }
        let insertStatement = try prepare("""
        INSERT INTO messages_fts (session_id, path, role, body) VALUES (?, ?, ?, ?);
        """)
        defer { insertStatement.finalize() }

        try beginTransaction()
        for session in sessions {
            try deleteStatement.reset()
            try deleteStatement.bind(1, session.id)
            try deleteStatement.run()

            let body = [session.name, session.preview]
                .compactMap { $0 }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            try insertStatement.reset()
            try insertStatement.bind(1, session.id)
            try insertStatement.bind(2, session.path)
            try insertStatement.bind(3, session.previewAuthor)
            try insertStatement.bind(4, body)
            try insertStatement.run()
        }
        try commitTransaction()
    }

    /// Huellas guardadas por ruta. Es contra esto que se compara el `stat` del sistema de archivos.
    public func fingerprints() throws -> [String: String] {
        try existingFingerprints()
    }

    /// Borra del índice las rutas que ya no existen en disco.
    public func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let sessionStatement = try prepare("DELETE FROM sessions WHERE path = ?;")
        defer { sessionStatement.finalize() }
        let textStatement = try prepare("DELETE FROM messages_fts WHERE path = ?;")
        defer { textStatement.finalize() }
        try inTransaction {
        for path in paths {
            try sessionStatement.reset()
            try sessionStatement.bind(1, path)
            try sessionStatement.run()
            try textStatement.reset()
            try textStatement.bind(1, path)
            try textStatement.run()
        }
        }
    }

    /// Todas las conversaciones guardadas, más recientes primero. Permite que la interfaz se arme
    /// **desde el índice** sin releer 271 archivos.
    public func allSessions() throws -> [SessionSummary] {
        let statement = try prepare("""
        SELECT id, path, cwd, project, name, modified, size FROM sessions
        ORDER BY modified DESC;
        """)
        defer { statement.finalize() }
        var result: [SessionSummary] = []
        while try statement.step() {
            guard let path = statement.string(1) else { continue }
            result.append(SessionSummary(
                id: statement.string(0) ?? path,
                path: path,
                project: statement.string(3) ?? "",
                cwd: statement.string(2),
                modified: Date(timeIntervalSince1970: statement.double(5)),
                sizeBytes: Int64(statement.double(6)),
                name: statement.string(4),
                // La vista previa vive en el FTS, no en la tabla: para el listado alcanza con
                // reconstruirla cuando se necesite (3.3). Acá se deja vacía a propósito.
                preview: try preview(for: statement.string(0) ?? path),
                previewAuthor: nil
            ))
        }
        return result
    }

    /// La vista previa se guarda dentro del texto buscable; se recupera sin reabrir el archivo.
    private func preview(for sessionID: String) throws -> String {
        let statement = try prepare("SELECT body FROM messages_fts WHERE session_id = ? LIMIT 1;")
        defer { statement.finalize() }
        try statement.bind(1, sessionID)
        guard try statement.step(), let body = statement.string(0) else { return "" }
        let lines = body.split(separator: "\n")
        return lines.count > 1 ? String(lines[1].prefix(160)) : String(body.prefix(160))
    }

    // MARK: - Grupos por tema

    /// Un grupo guardado, listo para volver a usarse o para asignarle una conversación nueva.
    public struct StoredCluster: Sendable {
        public let id: Int
        public let topTerms: [String]
        public let size: Int
        public let centroid: [String: Double]
        public let threshold: Double

        /// Público a propósito: las verificaciones arman grupos a mano para probar las reglas de
        /// sugerencia sin depender del historial de nadie.
        public init(id: Int, topTerms: [String], size: Int,
                    centroid: [String: Double], threshold: Double) {
            self.id = id
            self.topTerms = topTerms
            self.size = size
            self.centroid = centroid
            self.threshold = threshold
        }
    }

    /// Reemplaza todos los grupos. Se usa en el agrupado completo; el incremental usa `assign`.
    public func saveClusters(_ clusters: [(id: Int, topTerms: [String], members: [String],
                                          centroid: [String: Double])],
                             threshold: Double) throws {
        try beginTransaction()
        do {
            try exec("DELETE FROM clusters;")
            let statement = try prepare("""
            INSERT INTO clusters (id, top_terms, size, centroid, threshold, computed_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { statement.finalize() }
            for cluster in clusters {
                try statement.reset()
                try statement.bind(1, Int64(cluster.id))
                try statement.bind(2, Self.encode(strings: cluster.topTerms))
                try statement.bind(3, Int64(cluster.members.count))
                try statement.bind(4, Self.encode(vector: cluster.centroid))
                try statement.bind(5, threshold)
                try statement.bind(6, Date().timeIntervalSince1970)
                try statement.run()
            }
            // Y la pertenencia por conversación.
            let assignStatement = try prepare("UPDATE sessions SET cluster_id = ? WHERE path = ?;")
            defer { assignStatement.finalize() }
            for cluster in clusters {
                for member in cluster.members {
                    try assignStatement.reset()
                    try assignStatement.bind(1, Int64(cluster.id))
                    try assignStatement.bind(2, member)
                    try assignStatement.run()
                }
            }
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }

    public func loadClusters() throws -> [StoredCluster] {
        let statement = try prepare("""
        SELECT id, top_terms, size, centroid, threshold FROM clusters ORDER BY id;
        """)
        defer { statement.finalize() }
        var result: [StoredCluster] = []
        while try statement.step() {
            result.append(StoredCluster(
                id: Int(statement.double(0)),
                topTerms: Self.decodeStrings(statement.string(1)),
                size: Int(statement.double(2)),
                centroid: Self.decodeVector(statement.string(3)),
                threshold: statement.double(4)
            ))
        }
        return result
    }

    /// Inserta o actualiza **un solo grupo**. Es lo que usa el camino incremental: reescribir todos los
    /// grupos para agregar una conversación sería justamente lo que se quiere evitar.
    public func upsertCluster(id: Int, topTerms: [String], size: Int,
                              centroid: [String: Double], threshold: Double) throws {
        let statement = try prepare("""
        INSERT INTO clusters (id, top_terms, size, centroid, threshold, computed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            top_terms = excluded.top_terms, size = excluded.size,
            centroid = excluded.centroid, threshold = excluded.threshold,
            computed_at = excluded.computed_at;
        """)
        defer { statement.finalize() }
        try statement.bind(1, Int64(id))
        try statement.bind(2, Self.encode(strings: topTerms))
        try statement.bind(3, Int64(size))
        try statement.bind(4, Self.encode(vector: centroid))
        try statement.bind(5, threshold)
        try statement.bind(6, Date().timeIntervalSince1970)
        try statement.run()
    }

    /// Asigna una conversación a un grupo, sin tocar los demás.
    public func setCluster(_ clusterID: Int, forPath path: String) throws {
        let statement = try prepare("UPDATE sessions SET cluster_id = ? WHERE path = ?;")
        defer { statement.finalize() }
        try statement.bind(1, Int64(clusterID))
        try statement.bind(2, path)
        try statement.run()
    }

    /// Actualiza el IDF del corpus **solo** por los términos de un documento nuevo.
    public func addToCorpusTerms(_ counts: [String: Int], newCorpusSize: Int) throws {
        let statement = try prepare("""
        INSERT INTO corpus_terms (term, df) VALUES (?, 1)
        ON CONFLICT(term) DO UPDATE SET df = df + 1;
        """)
        defer { statement.finalize() }
        let meta = try prepare("""
        INSERT INTO meta (key, value) VALUES ('corpus_size', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        defer { meta.finalize() }
        try beginTransaction()
        do {
            for term in Set(counts.keys) {
                try statement.reset()
                try statement.bind(1, term)
                try statement.run()
            }
            try meta.reset()
            try meta.bind(1, String(newCorpusSize))
            try meta.run()
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }

    /// Las conversaciones de un grupo.
    public func paths(inCluster clusterID: Int) throws -> [String] {
        let statement = try prepare("SELECT path FROM sessions WHERE cluster_id = ? ORDER BY path;")
        defer { statement.finalize() }
        try statement.bind(1, Int64(clusterID))
        var result: [String] = []
        while try statement.step() {
            if let path = statement.string(0) { result.append(path) }
        }
        return result
    }

    /// Guarda los **conteos crudos** de términos de una conversación.
    ///
    /// Se guardan conteos y no el vector con IDF a propósito: el IDF depende del corpus entero y cambia
    /// cuando aparece una conversación nueva, así que aplicarlo es tarea del agrupado, no del indexado.
    public func saveSignatureCounts(_ counts: [String: Int], forPath path: String) throws {
        let statement = try prepare("UPDATE sessions SET signature = ? WHERE path = ?;")
        defer { statement.finalize() }
        try statement.bind(1, Self.encode(counts: counts))
        try statement.bind(2, path)
        try statement.run()
    }

    /// Los conteos guardados de cada conversación.
    public func loadSignatureCounts() throws -> [String: [String: Int]] {
        let statement = try prepare("SELECT path, signature FROM sessions WHERE signature IS NOT NULL;")
        defer { statement.finalize() }
        var result: [String: [String: Int]] = [:]
        while try statement.step() {
            guard let path = statement.string(0) else { continue }
            result[path] = Self.decodeCounts(statement.string(1))
        }
        return result
    }

    static func encode(counts: [String: Int]) -> String {
        let pairs = counts.sorted { $0.key < $1.key }.map { [$0.key, $0.value] as [Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeCounts(_ text: String?) -> [String: Int] {
        guard let text, let data = text.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [:] }
        var result: [String: Int] = [:]
        for pair in pairs {
            guard pair.count == 2, let term = pair[0] as? String, let count = pair[1] as? Int else { continue }
            result[term] = count
        }
        return result
    }

    /// Guarda la firma de una conversación, para no volver a leer el archivo.
    public func saveSignature(_ signature: [String: Double], topTerms: [String], forPath path: String) throws {
        let statement = try prepare("""
        UPDATE sessions SET signature = ?, cluster_id = ? WHERE path = ?;
        """)
        defer { statement.finalize() }
        try statement.bind(1, Self.encode(vector: signature))
        try statement.bind(2, Int64(0))
        try statement.bind(3, path)
        try statement.run()
        _ = topTerms
    }

    /// Guarda el nombre que puso el modelo para un grupo, por su clave estable.
    public func saveClusterName(_ name: String, forKey key: String) throws {
        let statement = try prepare("""
        INSERT INTO cluster_names (key, name, made_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET name = excluded.name, made_at = excluded.made_at;
        """)
        defer { statement.finalize() }
        try statement.bind(1, key)
        try statement.bind(2, name)
        try statement.bind(3, Date().timeIntervalSince1970)
        try statement.run()
    }

    /// Los nombres ya puestos, por clave. Es la caché: un grupo no se renombra dos veces.
    public func clusterNames() throws -> [String: String] {
        let statement = try prepare("SELECT key, name FROM cluster_names;")
        defer { statement.finalize() }
        var result: [String: String] = [:]
        while try statement.step() {
            guard let key = statement.string(0), let name = statement.string(1) else { continue }
            result[key] = name
        }
        return result
    }

    /// El IDF del corpus: cuántas conversaciones contienen cada término. Es lo que hace comparables las
    /// firmas viejas con una nueva.
    public func saveCorpusTerms(_ terms: [String: Int], corpusSize: Int) throws {
        try beginTransaction()
        do {
            try exec("DELETE FROM corpus_terms;")
            let statement = try prepare("INSERT INTO corpus_terms (term, df) VALUES (?, ?);")
            defer { statement.finalize() }
            for (term, df) in terms {
                try statement.reset()
                try statement.bind(1, term)
                try statement.bind(2, Int64(df))
                try statement.run()
            }
            let meta = try prepare("""
            INSERT INTO meta (key, value) VALUES ('corpus_size', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            defer { meta.finalize() }
            try meta.reset()
            try meta.bind(1, String(corpusSize))
            try meta.run()
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }

    public func loadCorpusTerms() throws -> (terms: [String: Int], corpusSize: Int) {
        let statement = try prepare("SELECT term, df FROM corpus_terms;")
        defer { statement.finalize() }
        var terms: [String: Int] = [:]
        while try statement.step() {
            guard let term = statement.string(0) else { continue }
            terms[term] = Int(statement.double(1))
        }
        let sizeStatement = try prepare("SELECT value FROM meta WHERE key = 'corpus_size';")
        defer { sizeStatement.finalize() }
        let size = try sizeStatement.step() ? Int(sizeStatement.string(0) ?? "0") ?? 0 : 0
        return (terms, size)
    }

    /// Las firmas guardadas, para no releer archivos.
    public func loadSignatures() throws -> [String: [String: Double]] {
        let statement = try prepare("SELECT path, signature FROM sessions WHERE signature IS NOT NULL;")
        defer { statement.finalize() }
        var result: [String: [String: Double]] = [:]
        while try statement.step() {
            guard let path = statement.string(0) else { continue }
            result[path] = Self.decodeVector(statement.string(1))
        }
        return result
    }

    static func encode(vector: [String: Double]) -> String {
        let pairs = vector.sorted { $0.key < $1.key }.map { [$0.key, $0.value] as [Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeVector(_ text: String?) -> [String: Double] {
        guard let text, let data = text.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [:] }
        var result: [String: Double] = [:]
        for pair in pairs {
            guard pair.count == 2, let term = pair[0] as? String else { continue }
            if let weight = pair[1] as? Double { result[term] = weight }
            else if let weight = pair[1] as? Int { result[term] = Double(weight) }
        }
        return result
    }

    static func encode(strings: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: strings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeStrings(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }

    // MARK: - Consultas

    public func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM sessions;")
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        return Int(statement.double(0))
    }

    public func searchableCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM messages_fts;")
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        return Int(statement.double(0))
    }

    /// Versión de esquema realmente guardada en el archivo.
    public func currentSchemaVersion() throws -> Int32 { try userVersion() }

    public func lastIndexedAt() throws -> Date? {
        let statement = try prepare("SELECT MAX(indexed_at) FROM sessions;")
        defer { statement.finalize() }
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return Date(timeIntervalSince1970: statement.double(0))
    }

    /// Un resultado de búsqueda con el fragmento donde coincide.
    public struct SearchHit: Sendable {
        public let path: String
        public let snippet: String
        public let role: String

        /// El fragmento viene con marcadores; la interfaz los usa para resaltar.
        public var parts: [String] { snippet.components(separatedBy: "\u{2}") }
    }

    /// Búsqueda con fragmento. FTS5 arma el extracto alrededor de la coincidencia, así que la
    /// interfaz no tiene que buscar la palabra ni recortar el texto a mano.
    public func searchHits(_ query: String, limit: Int = 60) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let statement = try prepare("""
        SELECT messages_fts.path,
               snippet(messages_fts, 3, '\u{2}', '\u{2}', '…', 14),
               messages_fts.role,
               bm25(messages_fts) AS score
        FROM messages_fts
        JOIN sessions ON sessions.id = messages_fts.session_id
        WHERE messages_fts MATCH ?
        ORDER BY score
        LIMIT ?;
        """)
        defer { statement.finalize() }
        // Se busca por prefijo además de por palabra: escribir "transcri" ya debería encontrar algo.
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        try statement.bind(1, "\"\(escaped)\"*")
        try statement.bind(2, Int64(limit))
        var hits: [SearchHit] = []
        var seen = Set<String>()
        while try statement.step() {
            guard let path = statement.string(0) else { continue }
            // Una conversación aparece una sola vez, con el mejor fragmento.
            guard seen.insert(path).inserted else { continue }
            hits.append(SearchHit(path: path,
                                  snippet: statement.string(1) ?? "",
                                  role: statement.string(2) ?? ""))
        }
        return hits
    }

    /// Búsqueda de texto completo. Devuelve las rutas que coinciden, más recientes primero.
    /// (La UI de búsqueda es el paso 3.3; el motor queda listo acá.)
    public func search(_ query: String, limit: Int = 50) throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let statement = try prepare("""
        SELECT sessions.path
        FROM messages_fts
        JOIN sessions ON sessions.id = messages_fts.session_id
        WHERE messages_fts MATCH ?
        ORDER BY sessions.modified DESC
        LIMIT ?;
        """)
        defer { statement.finalize() }
        // Se escapan las comillas para que un texto raro no rompa la consulta FTS.
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        try statement.bind(1, "\"\(escaped)\"")
        try statement.bind(2, Int64(limit))
        var paths: [String] = []
        while try statement.step() {
            if let path = statement.string(0) { paths.append(path) }
        }
        return paths
    }

    // MARK: - Plomería de SQLite

    /// Consolida el WAL y lo trunca. Se llama **después de cada lote de indexado**, que es el único
    /// momento en que el archivo crece, y al cerrar.
    ///
    /// `TRUNCATE` deja el archivo en cero en vez de solo marcarlo: es lo que devuelve el espacio en
    /// disco. Requiere un lock exclusivo, así que se hace cuando no hay una transacción abierta.
    public func checkpoint() {
        lock.lock(); defer { lock.unlock() }
        guard transactionDepth == 0, handle != nil else { return }
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Abre una transacción si no hay una abierta. Se puede anidar sin romper nada.
    public func beginTransaction() throws {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth == 0 { try exec("BEGIN;") }
        transactionDepth += 1
    }

    public func commitTransaction() throws {
        lock.lock(); defer { lock.unlock() }
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        if transactionDepth == 0 { try exec("COMMIT;") }
    }

    public func rollbackTransaction() {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth > 0 { try? exec("ROLLBACK;") }
        transactionDepth = 0
    }

    /// Envuelve un bloque en una transacción, reusando la que ya esté abierta.
    func inTransaction(_ body: () throws -> Void) throws {
        try beginTransaction()
        do {
            try body()
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw IndexError.open("índice cerrado") }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "código \(result)"
            sqlite3_free(error)
            throw IndexError.step(detail)
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw IndexError.open("índice cerrado") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw IndexError.statement(String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(statement)
    }

    /// Envoltorio mínimo sobre `sqlite3_stmt`. Existe para que el resto del archivo se lea como SQL.
    final class Statement {
        private var pointer: OpaquePointer?

        init(_ pointer: OpaquePointer) { self.pointer = pointer }

        func finalize() {
            if let pointer { sqlite3_finalize(pointer) }
            pointer = nil
        }

        @discardableResult
        func step() throws -> Bool {
            guard let pointer else { return false }
            let code = sqlite3_step(pointer)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw IndexError.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(pointer))))
            }
        }

        func run() throws { _ = try step() }

        func reset() throws {
            guard let pointer else { return }
            guard sqlite3_reset(pointer) == SQLITE_OK else {
                throw IndexError.step("no se pudo reiniciar la sentencia")
            }
        }

        func bind(_ index: Int32, _ value: String?) throws {
            guard let pointer else { return }
            guard let value else {
                sqlite3_bind_null(pointer, index)
                return
            }
            guard sqlite3_bind_text(pointer, index, value, -1, Self.transient) == SQLITE_OK else {
                throw IndexError.step("no se pudo enlazar texto")
            }
        }

        func bind(_ index: Int32, _ value: Int64) throws {
            guard let pointer else { return }
            guard sqlite3_bind_int64(pointer, index, value) == SQLITE_OK else {
                throw IndexError.step("no se pudo enlazar entero")
            }
        }

        func bind(_ index: Int32, _ value: Double) throws {
            guard let pointer else { return }
            guard sqlite3_bind_double(pointer, index, value) == SQLITE_OK else {
                throw IndexError.step("no se pudo enlazar número")
            }
        }

        func string(_ column: Int32) -> String? {
            guard let pointer, let text = sqlite3_column_text(pointer, column) else { return nil }
            return String(cString: text)
        }

        func double(_ column: Int32) -> Double {
            guard let pointer else { return 0 }
            return sqlite3_column_double(pointer, column)
        }

        func int32(_ column: Int32) -> Int32 {
            guard let pointer else { return 0 }
            return sqlite3_column_int(pointer, column)
        }

        func isNull(_ column: Int32) -> Bool {
            guard let pointer else { return true }
            return sqlite3_column_type(pointer, column) == SQLITE_NULL
        }

        /// Copia el texto en vez de guardar el puntero: Swift libera el `String` al salir de scope.
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
