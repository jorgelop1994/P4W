import Foundation

/// Una sugerencia de space: un grupo de conversaciones que parece un tema, con la etiqueta que el propio
/// grupo propone (sus términos más pesados) y **sin usar ningún modelo**.
public struct ClusterSuggestion: Sendable, Identifiable, Equatable {
    /// Clave estable entre re-agrupados: los términos del grupo, no su número. El número cambia cada vez
    /// que se vuelve a agrupar; los términos del tema, no.
    public let key: String
    public let topTerms: [String]
    public let members: [String]
    /// Nombre puesto por el modelo, si se pidió y salió bien. `nil` = se usa el heurístico.
    public var modelName: String?

    public init(key: String, topTerms: [String], members: [String], modelName: String? = nil) {
        self.key = key
        self.topTerms = topTerms
        self.members = members
        self.modelName = modelName
    }

    /// Lo que se muestra: el nombre del modelo si existe, y si no la etiqueta heurística. **Siempre hay
    /// algo**: si el modelo falla o está apagado, el grupo no queda sin nombre.
    public var displayName: String { modelName ?? suggestedName }

    public var id: String { key }
    public var size: Int { members.count }

    /// Nombre propuesto para el space. Se capitaliza porque va a quedar como título.
    public var suggestedName: String {
        topTerms.prefix(3).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " · ")
    }

    public var summary: String {
        "\(size) conversación\(size == 1 ? "" : "es")"
    }
}

/// Decide **qué** vale la pena proponer. Es lógica pura y del modelo: así se verifica sin depender de
/// tener el historial de alguien.
public enum ClusterSuggestions {

    public static func key(for topTerms: [String]) -> String {
        topTerms.sorted().joined(separator: "|")
    }

    /// Construye las sugerencias a partir de los grupos guardados.
    ///
    /// Se descartan:
    /// - los grupos de **una sola** conversación (proponer un space para una conversación es ruido);
    /// - los que ya tienen todas sus conversaciones en algún space (ya están organizadas);
    /// - los que la persona **ya ignoró**, porque si no volverían a aparecer en cada arranque.
    public static func build(clusters: [SessionIndex.StoredCluster],
                             membersByCluster: [Int: [String]],
                             assignedPaths: Set<String>,
                             dismissed: Set<String>,
                             names: [String: String] = [:],
                             minimumSize: Int = 2) -> [ClusterSuggestion] {
        var result: [ClusterSuggestion] = []
        for cluster in clusters {
            let members = (membersByCluster[cluster.id] ?? []).sorted()
            guard members.count >= minimumSize else { continue }
            let key = key(for: cluster.topTerms)
            guard !dismissed.contains(key) else { continue }
            // Si ya está todo adentro de un space, no hay nada que proponer. Si queda algo afuera, sí:
            // la sugerencia puede sumar lo que falta.
            let pending = members.filter { !assignedPaths.contains($0) }
            guard pending.count >= minimumSize else { continue }
            result.append(ClusterSuggestion(key: key, topTerms: cluster.topTerms,
                                            members: pending, modelName: names[key]))
        }
        // Orden: primero lo que más agrupa. A igual tamaño, por etiqueta, para que sea estable.
        return result.sorted { left, right in
            left.size != right.size ? left.size > right.size : left.key < right.key
        }
    }
}
