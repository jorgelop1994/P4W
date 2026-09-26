import Foundation

/// Orquesta el indexado incremental: **mira antes de leer**.
///
/// El costo de 3.1 estaba en leer el catálogo completo (0,19 s de 0,20 s). Este tipo compara el
/// `stat` del sistema de archivos contra las huellas guardadas y **solo abre lo que cambió**, así
/// que el arranque no depende del tamaño del historial: con 271 conversaciones o con 2.000, una
/// corrida sin cambios no abre ningún archivo.
public enum SessionIndexer {

    public struct Result: Sendable {
        public var filesOnDisk = 0
        public var added = 0
        public var updated = 0
        public var removed = 0
        public var unchanged = 0
        public var unreadable = 0
        public var indexedTotal = 0
        /// Sesiones cuyo texto se reindexó porque cambió *qué* se indexa, no el archivo.
        public var textUpgraded = 0
        public var messagesIndexed = 0
        /// Cuánto texto entró al buscador. Sirve para explicar el costo cuando parece alto.
        public var textCharacters = 0

        public var scanElapsed: TimeInterval = 0
        public var parseElapsed: TimeInterval = 0
        public var writeElapsed: TimeInterval = 0

        public var totalElapsed: TimeInterval { scanElapsed + parseElapsed + writeElapsed }

        private func label(_ value: TimeInterval) -> String {
            value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
        }

        public var summary: String {
            "\(filesOnDisk) en disco · \(added) nuevas · \(updated) actualizadas · "
                + "\(removed) borradas · \(unchanged) sin cambios"
                + (textUpgraded > 0 ? " · \(textUpgraded) con texto actualizado" : "")
        }

        /// Desglose honesto: separa mirar (barato) de abrir (caro).
        public var timing: String {
            "mirar \(label(scanElapsed)) + abrir \(label(parseElapsed)) + escribir \(label(writeElapsed))"
                + " = \(label(totalElapsed))"
        }
    }

    /// Pone el índice al día con el disco. Es idempotente: correrlo dos veces seguidas no cambia nada.
    @discardableResult
    public static func refresh(index: SessionIndex,
                               root: String = SessionCatalog.defaultRoot) throws -> Result {
        var result = Result()

        // 1. Mirar: solo `stat` por archivo, sin abrir ninguno.
        let scanStarted = Date()
        let entries = SessionCatalog.scan(root: root)
        result.scanElapsed = Date().timeIntervalSince(scanStarted)
        result.filesOnDisk = entries.count

        let known = try index.fingerprints()
        let pathsOnDisk = Set(entries.map(\.path))
        // Sesiones cuyo texto quedó en una versión vieja: hay que reindexarlo aunque el archivo no
        // haya cambiado. Pasó en la migración a v2, de la vista previa a los mensajes completos.
        let staleText = try index.pathsNeedingText()

        // 2. Decidir qué abrir: lo nuevo, lo que cambió, o lo que necesita texto nuevo.
        var toParse: [SessionCatalog.FileEntry] = []
        for entry in entries {
            if known[entry.path] == entry.fingerprint, !staleText.contains(entry.path) {
                result.unchanged += 1
            } else {
                toParse.append(entry)
                if known[entry.path] == entry.fingerprint { result.textUpgraded += 1 }
            }
        }

        // 3. Abrir solo eso, y sacar además el texto buscable.
        let parseStarted = Date()
        var summaries: [SessionSummary] = []
        var extracted: [(summary: SessionSummary, rows: [(role: String, body: String)])] = []
        /// Conteos temáticos por conversación: lo que después agrupa, sin volver a leer nada.
        var signatureCounts: [String: [String: Int]] = [:]
        for entry in toParse {
            guard var summary = SessionCatalog.summarize(path: entry.path, project: entry.project) else {
                // Un archivo ilegible no se cuenta como indexado ni se silencia.
                result.unreadable += 1
                continue
            }
            if known[entry.path] == nil { result.added += 1 }
            else if !staleText.contains(entry.path) { result.updated += 1 }

            let text = SessionReader.searchableText(path: entry.path)
            if summary.name == nil, let name = text.name { summary.name = name }
            summaries.append(summary)
            extracted.append((summary, text.rows))

            // Y la firma temática, acá mismo: el texto ya está en la mano, así que calcularla ahora sale
            // gratis y evita releer 470 archivos después solo para agrupar.
            let firstUserMessage = text.rows.first { $0.role == "user" }?.body
            let documentText = TextSignature.documentText(
                name: summary.name,
                firstUserMessage: firstUserMessage,
                paths: [summary.cwd ?? "", firstUserMessage ?? "", summary.path]
            )
            if !documentText.isEmpty {
                signatureCounts[entry.path] = TextSignature.termCounts(documentText)
            }
        }
        result.parseElapsed = Date().timeIntervalSince(parseStarted)

        // 4. Escribir solo lo que cambió, y sacar lo que ya no está.
        let writeStarted = Date()
        // Una sola transacción para todo el lote. Con una por sesión, 467 sesiones tardaban 18,45 s
        // (medido): el costo estaba en los commits, no en el trabajo.
        try index.beginTransaction()
        do {
            if !summaries.isEmpty { try index.index(summaries) }
            for item in extracted {
                try index.replaceText(
                    sessionID: item.summary.id,
                    path: item.summary.path,
                    rows: item.rows.map { SessionIndex.TextRow(role: $0.role, body: $0.body) }
                )
                result.messagesIndexed += item.rows.count
                result.textCharacters += item.rows.reduce(0) { $0 + $1.body.count }
            }
            // Las firmas van en la misma transacción que el resto: o queda todo, o no queda nada.
            for (path, counts) in signatureCounts {
                try index.saveSignatureCounts(counts, forPath: path)
            }
            try index.commitTransaction()
        } catch {
            index.rollbackTransaction()
            throw error
        }
        let deleted = known.keys.filter { !pathsOnDisk.contains($0) }
        if !deleted.isEmpty {
            try index.remove(paths: deleted)
            result.removed = deleted.count
        }
        // Y se consolida el WAL: es el único momento en que el archivo crece.
        index.checkpoint()
        result.writeElapsed = Date().timeIntervalSince(writeStarted)

        result.indexedTotal = try index.count()
        return result
    }
}
