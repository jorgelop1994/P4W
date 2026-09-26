import Foundation

/// Orden y filtro del panel de agentes.
///
/// Está aparte y es puro a propósito: el orden por atención y el filtro son **lógica del modelo**, no
/// de la vista, y así se pueden verificar sin depender de que una conversación real se bloquee en el
/// momento justo. Es la decisión 30 del plan: la atención es `blocked`, y es lo único que te necesita.
///
/// El vocabulario de estados se adoptó de herdr y de `pi-agent-board` (§7.8).
public enum AgentAttention {

    /// Un pedido de interacción pendiente es lo único que **requiere** a la persona. Lo demás puede
    /// esperar, así que va después.
    public static func needsYou(_ summary: InstanceSummary) -> Bool {
        summary.state == .blocked || summary.pendingDialogs > 0
    }

    /// Menor número = más urgente. El orden es: te necesita → trabajando → arrancando → falló →
    /// ocioso → sin proceso.
    ///
    /// `failed` va después de `working` a propósito: una conversación que trabaja está haciendo algo
    /// útil; una que falló ya no va a avanzar sola, pero tampoco pide nada.
    public static func rank(_ state: InstanceState, pendingDialogs: Int = 0) -> Int {
        if pendingDialogs > 0 || state == .blocked { return 0 }
        switch state {
        case .blocked: return 0
        case .working: return 1
        case .starting: return 2
        case .failed: return 3
        case .reaping: return 4
        case .idle: return 5
        case .cold: return 6
        }
    }

    /// Ordena por atención y, a igual atención, por tiempo ocioso: lo que lleva más tiempo esperando
    /// va primero, que es lo que uno quiere ver.
    public static func sorted(_ summaries: [InstanceSummary]) -> [InstanceSummary] {
        summaries.sorted { left, right in
            let leftRank = rank(left.state, pendingDialogs: left.pendingDialogs)
            let rightRank = rank(right.state, pendingDialogs: right.pendingDialogs)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.idleSeconds > right.idleSeconds
        }
    }

    /// Cuántas conversaciones te están necesitando.
    public static func attentionCount(_ summaries: [InstanceSummary]) -> Int {
        summaries.filter(needsYou).count
    }

    /// Filtro con la misma forma que usa `pi-agent-board`: `s:estado` para el estado y texto libre
    /// para el resto. Varios términos se combinan con "y".
    ///
    /// ```
    /// s:blocked          → solo las que te necesitan
    /// s:working lean     → las que trabajan y corren con el perfil lean
    /// herdr              → las que mencionen "herdr" en la sesión, el perfil o el modelo
    /// ```
    public static func filtered(_ summaries: [InstanceSummary], query: String) -> [InstanceSummary] {
        let terms = query
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return summaries }

        return summaries.filter { summary in
            terms.allSatisfy { term in matches(summary, term: term) }
        }
    }

    private static func matches(_ summary: InstanceSummary, term: String) -> Bool {
        if term.hasPrefix("s:") {
            let wanted = String(term.dropFirst(2))
            return summary.state.rawValue.lowercased().hasPrefix(wanted)
        }
        // Se busca en lo que la persona puede reconocer: la ruta de la sesión, el perfil y el modelo.
        let haystack = [
            summary.sessionKey,
            summary.sessionID,
            summary.profileName,
            summary.modelID ?? "",
        ].joined(separator: " ").lowercased()
        return haystack.contains(term)
    }

    /// Estados que existen hoy en el panel, para ofrecerlos como filtro sin inventarlos.
    public static func presentStates(_ summaries: [InstanceSummary]) -> [InstanceState] {
        let order: [InstanceState] = [.blocked, .working, .starting, .failed, .idle, .cold, .reaping]
        let present = Set(summaries.map(\.state))
        return order.filter { present.contains($0) }
    }
}
