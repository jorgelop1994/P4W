import Foundation

/// En qué anda Pi, para el avatar.
///
/// Los estados son **derivados**, no inventados: cada uno sale de un evento o de un estado que ya existe.
/// El gato no puede decir algo que el stream no esté diciendo.
public enum CatState: String, Sendable, CaseIterable {
    /// No hay ninguna instancia viva: no es lo mismo que estar en reposo, y no se ve igual.
    case dormido
    /// Hay instancia, pero no está corriendo nada.
    case enReposo
    /// Un run activo que todavía no produjo nada visible, o que está razonando.
    case pensando
    /// Está escribiendo la respuesta (llega texto).
    case escribiendo
    /// Está usando una herramienta.
    case trabajando
    /// Espera algo de la persona: un diálogo, una confirmación. **Es el estado más importante**: es el
    /// único donde el gato pide algo.
    case esperandote
    /// El último run terminó con error.
    case problema

    /// Etiqueta de texto. El gato **nunca** es la única señal: esto lo acompaña, y es lo que hace que el
    /// avatar siga informando con "Reducir movimiento" activo.
    public var label: String {
        switch self {
        case .dormido: return "sin conversación abierta"
        case .enReposo: return "en reposo"
        case .pensando: return "pensando…"
        case .escribiendo: return "escribiendo…"
        case .trabajando: return "usando herramientas…"
        case .esperandote: return "te espera"
        case .problema: return "terminó con error"
        }
    }

    /// La versión corta, para cuando al lado hay algo que no puede correrse: el campo de texto del
    /// compositor. Es la misma información, sin las palabras que se pueden deducir del contexto.
    public var shortLabel: String {
        switch self {
        case .dormido: return "sin sesión"
        case .enReposo: return "en reposo"
        case .pensando: return "pensando"
        case .escribiendo: return "escribiendo"
        case .trabajando: return "trabajando"
        case .esperandote: return "te espera"
        case .problema: return "error"
        }
    }

    /// Si el estado pide que la persona haga algo. Lo usa el panel para ordenar por atención.
    public var needsAttention: Bool { self == .esperandote || self == .problema }
}

/// Lo que se mira para decidir el estado. Se recibe todo junto y ya resuelto: así la derivación es pura y
/// se verifica con datos fabricados, sin lanzar un proceso ni hablar con un modelo.
public struct CatStateInput: Sendable, Equatable {
    /// Hay una instancia de Pi viva para la conversación abierta.
    public var hasInstance: Bool
    /// Hay un run en curso (entre el prompt y `agent_settled`).
    public var isRunActive: Bool
    /// Diálogos esperando respuesta. Es lo que bloquea todo lo demás.
    public var pendingDialogs: Int
    /// Herramientas en curso.
    public var runningTools: Int
    /// Qué llegó último: `thinking` o `text`. `nil` = todavía nada en este run.
    public var lastContent: ContentKind?
    /// El último run terminó con error.
    public var lastRunFailed: Bool

    public enum ContentKind: String, Sendable, Equatable { case thinking, text }

    public init(hasInstance: Bool, isRunActive: Bool, pendingDialogs: Int = 0,
                runningTools: Int = 0, lastContent: ContentKind? = nil,
                lastRunFailed: Bool = false) {
        self.hasInstance = hasInstance
        self.isRunActive = isRunActive
        self.pendingDialogs = pendingDialogs
        self.runningTools = runningTools
        self.lastContent = lastContent
        self.lastRunFailed = lastRunFailed
    }
}

/// Deriva el estado. El orden de las reglas **es** la decisión, así que está explicado regla por regla.
public enum CatStateMachine {

    public static func derive(_ input: CatStateInput) -> CatState {
        // 1. Pedir algo a la persona gana sobre todo lo demás: es lo único que requiere acción, y taparlo
        //    con otro estado sería esconder lo que importa.
        if input.pendingDialogs > 0 { return .esperandote }
        // 2. Un error del último run se ve hasta que el próximo run arranque. Si no, el gato diría
        //    "en reposo" después de una falla.
        if input.lastRunFailed && !input.isRunActive { return .problema }
        // 3. Sin instancia no hay reposo: no hay nada. Se distinguen porque la persona ve cosas distintas.
        guard input.hasInstance else { return .dormido }
        // 4. Con el run terminado, en reposo — y acá el error ya se miró arriba.
        guard input.isRunActive else { return .enReposo }
        // 5. Una herramienta corriendo gana sobre el pensamiento: es lo que está haciendo *ahora*.
        if input.runningTools > 0 { return .trabajando }
        // 6. Si no, se muestra lo que está llegando.
        switch input.lastContent {
        case .text: return .escribiendo
        case .thinking, .none: return .pensando
        }
    }

    /// Deriva el estado desde lo que ya existe en la app, sin agregar una segunda fuente de verdad.
    ///
    /// Ojo con `InstanceState.blocked`: ya significa "hay un diálogo esperando". Y con `cold` y `.failed`
    /// no hay proceso vivo, así que no hay nada que animar.
    public static func derive(instanceState: InstanceState?, isRunActive: Bool,
                              pendingDialogs: Int, runningTools: Int,
                              liveThinking: String, liveText: String,
                              lastRunFailed: Bool) -> CatState {
        // Qué llegó último. No es un orden de llegada exacto —no se guarda un historial aparte solo para
        // esto— pero no inventa nada: si hay texto y además pensamiento, manda el pensamiento, que es lo
        // que Pi emite mientras sigue razonando antes de escribir de nuevo.
        var last: CatStateInput.ContentKind?
        if !liveText.isEmpty { last = .text }
        if !liveThinking.isEmpty { last = .thinking }

        let alive = instanceState != nil && instanceState != .cold && instanceState != .failed
        // Un diálogo pendiente bloquea aunque el contador venga vacío, porque el estado ya lo dice.
        let dialogs = max(pendingDialogs, instanceState == .blocked ? 1 : 0)

        return derive(CatStateInput(
            hasInstance: alive,
            isRunActive: isRunActive || instanceState == .working || instanceState == .starting,
            pendingDialogs: dialogs,
            runningTools: runningTools,
            lastContent: last,
            lastRunFailed: lastRunFailed
        ))
    }
}
