import Foundation

/// Guarda y mantiene los grupos por tema en el índice.
///
/// La parte que importa es **el camino incremental**: una conversación nueva se asigna a un grupo
/// existente comparando su firma contra los centroides guardados, **sin volver a agrupar todo**. Para
/// que eso sea posible hay que guardar dos cosas que normalmente se tiran al terminar:
///
/// - el **IDF del corpus** (cuántas conversaciones contienen cada término), porque sin él la firma de la
///   conversación nueva no sería comparable con los centroides guardados;
/// - el **centroide** de cada grupo, que es contra lo que se compara.
///
/// **Aproximación honesta:** al agregar una conversación, el IDF del corpus cambia para todos, pero acá
/// solo se actualiza el de los términos nuevos. Es decir, los centroides viejos quedan calculados con el
/// IDF anterior. Para asignar alcanza y sobra; si el corpus cambia mucho, un agrupado completo lo
/// recalcula todo. Se prefiere eso a re-agrupar 470 conversaciones cada vez que aparece una.
public enum ClusterIndexer {

    public struct Outcome: Sendable {
        public let clusterID: Int
        public let createdNewCluster: Bool
        public let similarity: Double
    }

    /// Agrupado completo **leyendo los conteos que ya están guardados**.
    ///
    /// No reabre un solo archivo: los conteos se calcularon durante el indexado, cuando el texto ya estaba
    /// en la mano. Devuelve cuántos grupos quedaron.
    @discardableResult
    public static func rebuild(index: SessionIndex, threshold: Double) throws -> Int {
        let counts = try index.loadSignatureCounts()
        guard !counts.isEmpty else { return 0 }
        return try save(signatures: ConversationClusterer.signatures(fromCounts: counts),
                        counts: counts, index: index, threshold: threshold)
    }

    /// Agrupado completo a partir de documentos sueltos. Se usa cuando el texto está en la mano y no
    /// interesa pasar por el índice.
    @discardableResult
    public static func rebuild(index: SessionIndex,
                               documents: [ConversationClusterer.Document],
                               threshold: Double) throws -> Int {
        var counts: [String: [String: Int]] = [:]
        for document in documents { counts[document.id] = TextSignature.termCounts(document.text) }
        for (path, value) in counts { try index.saveSignatureCounts(value, forPath: path) }
        return try save(signatures: ConversationClusterer.signatures(fromCounts: counts),
                        counts: counts, index: index, threshold: threshold)
    }

    private static func save(signatures: [String: ConversationSignature],
                             counts: [String: [String: Int]],
                             index: SessionIndex, threshold: Double) throws -> Int {
        let clusters = ConversationClusterer.clusters(from: signatures, threshold: threshold)

        try index.saveClusters(
            clusters.map { cluster in
                (id: cluster.index, topTerms: cluster.topTerms, members: cluster.members,
                 centroid: ConversationClusterer.centroid(of: cluster.members, in: signatures))
            },
            threshold: threshold
        )

        // El IDF del corpus es lo que después permite asignar una conversación nueva sin re-agrupar.
        var documentFrequency: [String: Int] = [:]
        for terms in counts.values {
            for term in terms.keys { documentFrequency[term, default: 0] += 1 }
        }
        try index.saveCorpusTerms(documentFrequency, corpusSize: counts.count)

        for cluster in clusters {
            for member in cluster.members { try index.setCluster(cluster.index, forPath: member) }
        }
        return clusters.count
    }

    /// Asigna a un grupo una conversación **cuyos conteos ya están guardados** en el índice.
    ///
    /// Es el camino normal: la firma se calculó al indexar, así que acá no se lee ningún archivo.
    public static func assign(index: SessionIndex, path: String, threshold: Double) throws -> Outcome? {
        let counts = try index.loadSignatureCounts()
        guard let terms = counts[path], !terms.isEmpty else { return nil }
        return try assign(index: index, path: path, counts: terms, threshold: threshold)
    }

    /// ¿Hay que re-agrupar?
    ///
    /// La primera versión de esto preguntaba solo "¿hay grupos guardados?". Estaba mal: alcanzaba con
    /// que quedara **un** grupo viejo para que nunca se re-agrupara, y se descubrió verificando la app
    /// (mostraba 1 grupo sobre 470 conversaciones). Ahora se compara el trabajo guardado contra el
    /// material disponible: si hay más conversaciones con firma que las que el corpus declara, o cambió
    /// el umbral, el resultado quedó viejo.
    public static func needsRebuild(index: SessionIndex, threshold: Double) throws -> Bool {
        let clusters = try index.loadClusters()
        if clusters.isEmpty { return true }
        if clusters.contains(where: { abs($0.threshold - threshold) > 0.0001 }) { return true }
        let corpus = try index.loadCorpusTerms()
        let signatures = try index.loadSignatureCounts().count
        return corpus.corpusSize != signatures
    }

    /// Asigna **una** conversación a un grupo existente, o crea uno nuevo si no se parece a ninguno.
    ///
    /// No recalcula nada de los demás: compara la firma contra los centroides guardados.
    public static func assign(index: SessionIndex,
                              document: ConversationClusterer.Document,
                              threshold: Double) throws -> Outcome {
        let counts = TextSignature.termCounts(document.text)
        // Los conteos se guardan antes de asignar: si no, esa conversación quedaría sin firma y un
        // re-agrupado posterior la dejaría afuera. En el camino normal los guarda el indexado, pero
        // asignar un documento suelto tiene que dejar el índice igual de completo.
        try index.saveSignatureCounts(counts, forPath: document.id)
        return try assign(index: index, path: document.id, counts: counts, threshold: threshold)
    }

    /// El cuerpo de la asignación: compara el vector del documento contra los centroides guardados.
    static func assign(index: SessionIndex, path: String, counts: [String: Int],
                       threshold: Double) throws -> Outcome {
        let corpus = try index.loadCorpusTerms()

        // La firma de la conversación nueva se arma con el IDF **guardado**. Un término que no está en el
        // corpus se trata como raro, que es lo correcto: apareció una sola vez.
        let size = Double(max(corpus.corpusSize, 1))
        var vector: [String: Double] = [:]
        for (term, frequency) in counts {
            let documentFreq = Double(corpus.terms[term] ?? 1)
            vector[term] = (1 + log(Double(frequency))) * log(1 + size / documentFreq)
        }
        let signature = ConversationClusterer.normalize(vector)

        // Contra qué se compara: contra los centroides guardados.
        let stored = try index.loadClusters()
        var best: (cluster: SessionIndex.StoredCluster, score: Double)?
        for cluster in stored {
            let score = ConversationClusterer.cosine(signature, cluster.centroid)
            if score > (best?.score ?? -1) { best = (cluster, score) }
        }

        guard let best, best.score >= threshold else {
            // No se parece a nada: nace un grupo nuevo. El identificador es el siguiente libre, así que
            // no se reutiliza aunque se borren grupos.
            let newID = (stored.map(\.id).max() ?? -1) + 1
            let topTerms = signature.sorted { $0.value > $1.value }.prefix(6).map(\.key)
            try index.upsertCluster(id: newID, topTerms: Array(topTerms), size: 1,
                                    centroid: signature, threshold: threshold)
            try index.setCluster(newID, forPath: path)
            try index.addToCorpusTerms(counts, newCorpusSize: corpus.corpusSize + 1)
            return Outcome(clusterID: newID, createdNewCluster: true, similarity: 0)
        }

        // Se suma al grupo: el centroide se actualiza como promedio ponderado por el tamaño, sin tocar
        // los otros grupos.
        let newSize = best.cluster.size + 1
        var blended = best.cluster.centroid
        for (term, weight) in signature {
            let previous = blended[term] ?? 0
            blended[term] = (previous * Double(best.cluster.size) + weight) / Double(newSize)
        }
        let centroid = ConversationClusterer.normalize(blended)
        let topTerms = centroid.sorted { left, right in
            left.value != right.value ? left.value > right.value : left.key < right.key
        }.prefix(6).map(\.key)

        try index.upsertCluster(id: best.cluster.id, topTerms: Array(topTerms), size: newSize,
                                centroid: centroid, threshold: threshold)
        try index.setCluster(best.cluster.id, forPath: path)
        try index.addToCorpusTerms(counts, newCorpusSize: corpus.corpusSize + 1)
        return Outcome(clusterID: best.cluster.id, createdNewCluster: false, similarity: best.score)
    }

    /// Frecuencia documental de cada término: en cuántas conversaciones aparece.
    static func corpusDocumentFrequency(_ documents: [ConversationClusterer.Document]) -> [String: Int] {
        var frequency: [String: Int] = [:]
        for document in documents {
            for term in Set(TextSignature.termCounts(document.text).keys) {
                frequency[term, default: 0] += 1
            }
        }
        return frequency
    }
}
