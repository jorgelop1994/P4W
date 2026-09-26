import Foundation

/// Cuándo avisar, y cuándo callarse.
///
/// Es lógica **pura y del modelo**, no de la vista: una notificación que decide mal es peor que no
/// tener notificaciones, y así se puede verificar sin depender de que algo se bloquee de verdad.
///
/// El principio es simple: **avisar solo de lo que la persona no puede ver por sí misma.**
///
/// - Si ya está mirando *esa* conversación, no hay nada que avisarle.
/// - Si P4W está en primer plano mirando otra cosa, los puntos de estado de la lista ya lo dicen.
/// - Si P4W no está en primer plano, no se ve nada: ahí sí corresponde avisar.
public enum NotificationPolicy {

    public enum Reason: String, Sendable {
        /// Una conversación quedó esperando una respuesta o una aprobación.
        case needsYou
        /// Una conversación terminó de trabajar.
        case finished
    }

    /// El título y el cuerpo se arman acá para que digan lo mismo en cualquier caso.
    public static func title(for reason: Reason) -> String {
        switch reason {
        case .needsYou: return "Pi te necesita"
        case .finished: return "Pi terminó"
        }
    }

    /// ¿Corresponde avisar que una conversación te necesita?
    ///
    /// - Parameters:
    ///   - sessionKey: la conversación que quedó esperando.
    ///   - visibleSessionKey: la que se está mirando, si hay alguna.
    ///   - appIsActive: si P4W está en primer plano.
    ///   - alreadyNotified: si ya se avisó de esta misma espera (para no repetir en cada latido).
    public static func shouldNotifyNeedsYou(sessionKey: String,
                                            visibleSessionKey: String?,
                                            appIsActive: Bool,
                                            alreadyNotified: Bool) -> Bool {
        guard !alreadyNotified else { return false }
        // Mirando exactamente esa conversación: no hay nada que avisar.
        if appIsActive, visibleSessionKey == sessionKey { return false }
        return true
    }

    /// ¿Corresponde avisar que una conversación terminó?
    ///
    /// Acá se es más conservador que con la atención: terminar no requiere a nadie, y con P4W en primer
    /// plano los puntos de la lista ya lo cuentan sin interrumpir.
    public static func shouldNotifyFinished(from previous: InstanceState,
                                            to current: InstanceState,
                                            appIsActive: Bool,
                                            alreadyNotified: Bool) -> Bool {
        guard !alreadyNotified, !appIsActive else { return false }
        // Solo cuando **deja** de trabajar. Un `idle` que sigue `idle` no es una novedad.
        let wasWorking = previous == .working || previous == .starting
        return wasWorking && (current == .idle || current == .failed)
    }

    /// Un cambio de estado, para poder reaccionar a transiciones de instancias que no son la visible.
    public struct Transition: Sendable, Equatable {
        public let sessionKey: String
        public let fromState: InstanceState
        public let toState: InstanceState

        public init(sessionKey: String, fromState: InstanceState, toState: InstanceState) {
            self.sessionKey = sessionKey
            self.fromState = fromState
            self.toState = toState
        }
    }

    /// Compara dos fotos del panel y devuelve solo las transiciones.
    ///
    /// Hace falta porque la app **no observa los eventos** de las conversaciones que no está mirando:
    /// las del fondo se conocen por la foto del supervisor. Comparar fotos es más simple que enganchar
    /// un observador por instancia, y para avisar alcanza.
    public static func transitions(from previous: [String: InstanceState],
                                   to current: [String: InstanceState]) -> [Transition] {
        var result: [Transition] = []
        for (key, state) in current {
            guard let before = previous[key], before != state else { continue }
            result.append(Transition(sessionKey: key, fromState: before, toState: state))
        }
        return result
    }

    /// Fotografía el estado por conversación, que es lo que se compara entre latidos.
    public static func states(of summaries: [InstanceSummary]) -> [String: InstanceState] {
        var result: [String: InstanceState] = [:]
        for summary in summaries { result[summary.sessionKey] = summary.state }
        return result
    }
}
