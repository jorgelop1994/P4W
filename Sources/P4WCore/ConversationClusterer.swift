import Foundation

extension ConversationClusterer.PairCandidate {
    /// ¿Este candidato le gana a otro? Ante empate exacto decide el par de identificadores, para que el
    /// resultado no dependa del orden de un diccionario.
    func beats(_ other: ConversationClusterer.PairCandidate) -> Bool {
        if score != other.score { return score > other.score }
        return (first, second) < (other.first, other.second)
    }
}

/// Firma vectorial de una conversación, lista para comparar con otras.
public struct ConversationSignature: Sendable {
    public let id: String
    /// Términos ponderados por TF‑IDF, con el vector ya normalizado.
    public let vector: [String: Double]
    /// Los términos que más pesan. Es lo que se usa para ponerle nombre a un grupo **sin modelo**.
    public let topTerms: [String]
}

/// Agrupa conversaciones por tema, **sin modelo**.
///
/// Es la capa 1 de la agrupación inteligente (§7.9 del plan). Las dos propiedades que la hacen usable
/// son las mismas que la hacen verificable:
///
/// - **Determinista**: el mismo conjunto da exactamente los mismos grupos, siempre. Agrupar con un LLM
///   no lo es — el mismo corpus da grupos distintos en cada corrida.
/// - **Local y gratis**: no llama a nada. En la Mac Intel no hay modelos locales, así que esto tiene que
///   funcionar solo.
///
/// El método es aglomerativo sobre **centroides** con similitud coseno: cada conversación empieza sola y
/// se van fusionando las dos más parecidas mientras superen el umbral.
public enum ConversationClusterer {

    public struct Document: Sendable {
        public let id: String
        public let text: String
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct Cluster: Sendable {
        /// Índice del grupo. Es un número porque el nombre lo pone la capa 2 (o los términos frecuentes).
        public let index: Int
        public let members: [String]
        /// Los términos que más pesan dentro del grupo: sirven como etiqueta provisional.
        public let topTerms: [String]

        public var size: Int { members.count }
    }

    // MARK: Firmas

    /// Calcula la firma de cada documento a partir de su texto.
    public static func signatures(_ documents: [Document]) -> [String: ConversationSignature] {
        var counts: [String: [String: Int]] = [:]
        for document in documents {
            counts[document.id] = TextSignature.termCounts(document.text)
        }
        return signatures(fromCounts: counts)
    }

    /// Calcula las firmas a partir de **conteos ya guardados**.
    ///
    /// Es la forma que usa P4W: los conteos se calculan una sola vez, durante el indexado, cuando el
    /// texto ya está en la mano. Así agrupar no implica volver a leer 470 archivos. El IDF, que sí es del
    /// corpus, se aplica acá.
    public static func signatures(fromCounts counts: [String: [String: Int]]) -> [String: ConversationSignature] {
        guard !counts.isEmpty else { return [:] }

        var documentFrequency: [String: Int] = [:]
        for terms in counts.values {
            for term in terms.keys { documentFrequency[term, default: 0] += 1 }
        }

        let total = Double(counts.count)
        var result: [String: ConversationSignature] = [:]

        for (id, terms) in counts {
            var vector: [String: Double] = [:]
            for (term, frequency) in terms {
                let documentFreq = Double(documentFrequency[term] ?? 1)
                // IDF suavizado: siempre positivo, y un término que aparece en todos pesa poco.
                let idf = log(1 + total / documentFreq)
                // TF logarítmico: la décima repetición de una palabra no aporta diez veces más.
                vector[term] = (1 + log(Double(frequency))) * idf
            }
            let normalized = normalize(vector)
            let top = normalized.sorted { left, right in
                left.value != right.value ? left.value > right.value : left.key < right.key
            }.prefix(8).map(\.key)
            result[id] = ConversationSignature(id: id, vector: normalized, topTerms: top)
        }
        return result
    }

    // MARK: Agrupado

    /// El par de grupos más parecido y cuánto se parecen.
    struct PairCandidate {
        let first: Int
        let second: Int
        let score: Double
    }

    /// Fusiona mientras la similitud entre los dos grupos más parecidos sea **al menos** el umbral.
    ///
    /// El orden de las fusiones está fijado: ante un empate se elige siempre el mismo par (por el
    /// identificador más chico), así que el resultado es reproducible aunque el diccionario no tenga orden.
    public static func clusters(from signatures: [String: ConversationSignature],
                               threshold: Double) -> [Cluster] {
        let ids = signatures.keys.sorted()
        guard !ids.isEmpty else { return [] }

        var state = ClusterState(ids: ids, signatures: signatures)
        while state.alive.count > 1 {
            guard let pair = bestPair(in: state, threshold: threshold) else { break }
            state.merge(pair)
        }
        return state.finish(signatures: signatures)
    }

    /// Busca el par a fusionar. Separado para que la fusión se lea como lo que es.
    private static func bestPair(in state: ClusterState, threshold: Double) -> PairCandidate? {
        var best: PairCandidate?
        for position in state.alive.indices {
            let left = state.alive[position]
            for other in state.alive.indices where other > position {
                let right = state.alive[other]
                let score = state.similarities[left][right]
                guard score >= threshold else { continue }
                let candidate = PairCandidate(first: min(left, right), second: max(left, right),
                                              score: score)
                if let current = best, !candidate.beats(current) { continue }
                best = candidate
            }
        }
        return best
    }

    /// Estado del agrupado: miembros y centroides por grupo, con la matriz de similitudes.
    struct ClusterState {
        var members: [Set<String>]
        var centroids: [[String: Double]]
        var similarities: [[Double]]
        var alive: [Int]

        init(ids: [String], signatures: [String: ConversationSignature]) {
            members = ids.map { [$0] }
            centroids = ids.map { signatures[$0]?.vector ?? [:] }
            similarities = []
            for index in ids.indices {
                var row = [Double](repeating: 0, count: ids.count)
                for other in ids.indices where other > index {
                    let value = cosine(centroids[index], centroids[other])
                    row[other] = value
                }
                similarities.append(row)
            }
            // La mitad superior ya está; la inferior se completa para poder consultar por cualquiera.
            for index in ids.indices {
                for other in ids.indices where other < index {
                    similarities[index][other] = similarities[other][index]
                }
            }
            alive = Array(ids.indices)
        }

        /// Junta dos grupos y actualiza solo lo que cambió: la fila y la columna del que queda.
        mutating func merge(_ pair: PairCandidate) {
            members[pair.first].formUnion(members[pair.second])
            centroids[pair.first] = normalize(blend(centroids[pair.first], centroids[pair.second]))
            members[pair.second] = []
            centroids[pair.second] = [:]

            for other in centroids.indices where other != pair.first && !centroids[other].isEmpty {
                let value = cosine(centroids[pair.first], centroids[other])
                similarities[pair.first][other] = value
                similarities[other][pair.first] = value
            }
            alive.removeAll { centroids[$0].isEmpty }
        }

        /// Arma los grupos finales: orden por tamaño y, a igual tamaño, por su miembro más chico.
        func finish(signatures: [String: ConversationSignature]) -> [Cluster] {
            let built = alive.map { index -> Cluster in
                let memberIDs = members[index].sorted()
                var summed: [String: Double] = [:]
                for member in memberIDs {
                    for (term, weight) in signatures[member]?.vector ?? [:] {
                        summed[term, default: 0] += weight
                    }
                }
                let top = summed.sorted { left, right in
                    left.value != right.value ? left.value > right.value : left.key < right.key
                }.prefix(6).map(\.key)
                return Cluster(index: 0, members: memberIDs, topTerms: top)
            }
            .sorted { left, right in
                left.size != right.size ? left.size > right.size
                                        : (left.members.first ?? "") < (right.members.first ?? "")
            }
            return built.enumerated().map {
                Cluster(index: $0.offset, members: $0.element.members, topTerms: $0.element.topTerms)
            }
        }
    }

    /// Promedio normalizado de los vectores de un grupo. Es lo que se guarda para poder asignar después.
    public static func centroid(of members: [String],
                                in signatures: [String: ConversationSignature]) -> [String: Double] {
        var summed: [String: Double] = [:]
        for member in members {
            for (term, weight) in signatures[member]?.vector ?? [:] { summed[term, default: 0] += weight }
        }
        return normalize(summed)
    }

    // MARK: Cuentas

    /// Similitud coseno. Los vectores vienen normalizados, así que es el producto punto.
    static func cosine(_ left: [String: Double], _ right: [String: Double]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        // Se recorre el más chico: menos operaciones y mismo resultado.
        let (small, large) = left.count <= right.count ? (left, right) : (right, left)
        var dot = 0.0
        for (term, weight) in small {
            if let other = large[term] { dot += weight * other }
        }
        return dot
    }

    static func normalize(_ vector: [String: Double]) -> [String: Double] {
        var sumSquares = 0.0
        for weight in vector.values { sumSquares += weight * weight }
        let length = sumSquares.squareRoot()
        guard length > 0 else { return [:] }
        var result: [String: Double] = [:]
        result.reserveCapacity(vector.count)
        for (term, weight) in vector { result[term] = weight / length }
        return result
    }

    /// Promedio de dos vectores, ponderado por la cantidad de documentos de cada grupo.
    static func blend(_ left: [String: Double], _ right: [String: Double]) -> [String: Double] {
        var result = left
        for (term, weight) in right {
            result[term, default: 0] += weight
        }
        return result
    }
}
