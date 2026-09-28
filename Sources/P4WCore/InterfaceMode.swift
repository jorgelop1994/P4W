import Foundation

/// Cuánta app se ve.
///
/// P4W tiene dos personas detrás: quien lo escribió —que quiere ver procesos, instancias, spaces y perfiles— y
/// quien solo quiere conversar. La misma app no puede pedirle a la segunda que entienda lo de la primera.
///
/// La decisión vive acá, fuera de las vistas, por la misma razón que el resto de las decisiones de este
/// proyecto: así se puede **verificar**. Y se verifica una propiedad que importa: que el modo simple sea un
/// **subconjunto** de la app, no una app distinta — nada aparece en simple que no esté en completa.
public enum InterfaceMode: String, Sendable, CaseIterable {
    /// Todo: panel de agentes, spaces, sugerencias, agrupación por proyecto y los selectores del encabezado.
    case completa
    /// Conversar y nada más: la lista de conversaciones **recientes** y el chat.
    case simple

    public var label: String {
        switch self {
        case .completa: return "Completa"
        case .simple: return "Simple"
        }
    }

    public var note: String {
        switch self {
        case .completa:
            return "Se ve todo: el panel de agentes, los spaces, las sugerencias y los selectores de modelo y perfil."
        case .simple:
            return "Para conversar: la lista de conversaciones recientes, el chat y el gato. "
                 + "Esconde lo de desarrollo. Nada de lo que se esconde se pierde: se puede volver a la vista completa."
        }
    }

    // Cada superficie, en un lugar. Las vistas preguntan por estas y no por el modo, así agregar una superficie
    // nueva obliga a decidir en qué modo se ve, en vez de olvidarse.

    /// El panel de agentes (instancias vivas, contadores, filtro).
    public var showsAgentPanel: Bool { self == .completa }
    /// Los spaces y sus pestañas.
    public var showsSpaces: Bool { self == .completa }
    /// Las sugerencias de agrupación del modelo.
    public var showsSuggestions: Bool { self == .completa }
    /// La agrupación del historial por proyecto. En simple, una lista sola por fecha.
    public var groupsByProject: Bool { self == .completa }
    /// Los selectores del encabezado: modelo, nivel de razonamiento y perfil de arranque.
    public var showsModelControls: Bool { self == .completa }
    /// Los encabezados de sección con su contador y su botón de plegar.
    public var showsSectionHeaders: Bool { self == .completa }

    /// Las superficies que se ven, por nombre. Es lo que permite **contarlas** y comprobar que el modo simple
    /// tiene menos, en vez de afirmarlo.
    public var visibleSurfaces: [String] {
        var superficies = ["lista de conversaciones", "chat", "barra de escritura", "gato", "nueva conversación"]
        if showsSpaces { superficies.append("spaces") }
        if showsSuggestions { superficies.append("sugerencias") }
        if groupsByProject { superficies.append("agrupación por proyecto") }
        if showsSectionHeaders { superficies.append("encabezados de sección") }
        if showsAgentPanel { superficies.append("panel de agentes") }
        if showsModelControls { superficies.append("selectores de modelo, razonamiento y perfil") }
        return superficies
    }

    /// Las que esconde respecto del otro modo. Dichas, para que la persona sepa qué está apagando.
    public var hiddenRespectToComplete: [String] {
        InterfaceMode.completa.visibleSurfaces.filter { !visibleSurfaces.contains($0) }
    }
}
