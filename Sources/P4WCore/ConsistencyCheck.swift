import Foundation

/// El veredicto de **«¿de qué conversación es esto?»** — la pregunta que ya falló tres veces.
///
/// Los tres bugs de esta familia se encontraron leyendo código, y los tres eran la misma pregunta contestada
/// mal:
///
/// 1. La salida de una conversación de fondo se dibujaba en la que se acababa de abrir (dueño del transcript).
/// 2. Dos conversaciones nuevas compartían dueño (la clave era la constante `"nueva"`).
/// 3. Mandar un mensaje con una conversación abierta en pantalla y que la app dijera «No hay conversación
///    abierta» —o, peor, que el mensaje **se fuera a otra conversación**— porque la referencia había quedado en
///    nil o vieja.
///
/// Está en el núcleo y es **puro** para que se pueda verificar: las tres formas de fallar se prueban en la
/// suite, sin abrir la app.
public enum ConsistencyVerdict: Equatable, Sendable {
    /// Todo en orden, y la clave de la conversación de la que se trata.
    case ok(clave: String)
    /// No hay nada abierto. No es una suposición violada: es simplemente que no hay conversación.
    case sinConversacion
    /// **Hay una conversación abierta y no hay referencia.** Es el «No hay conversación abierta» con una
    /// conversación en pantalla.
    case envioSinReferencia(visible: String?)
    /// Dos de las tres partes no hablan de lo mismo: la referencia, la conversación visible o la instancia viva.
    /// Es la mezcla de mensajes, en cualquiera de sus formas.
    case noCoincide(ref: String?, visible: String?, instancia: String?)

    /// Si esto significa que **algo se rompió**, y no simplemente que no había nada que hacer.
    public var isViolation: Bool {
        switch self {
        case .ok, .sinConversacion: return false
        case .envioSinReferencia, .noCoincide: return true
        }
    }

    /// Con qué evento se registra. Las violaciones son `fault` (una suposición rota, en el vocabulario de
    /// `os.Logger`), y el caso bueno queda en `debug` para no llenar el log de lo que sale bien.
    public var event: LogEvent {
        switch self {
        case .ok: return .consistenciaOk
        case .sinConversacion, .envioSinReferencia, .noCoincide: return .consistenciaRota
        }
    }

    /// Un motivo corto y de **nuestro** vocabulario, nunca texto de nadie.
    public var motivo: String {
        switch self {
        case .ok: return "coincide"
        case .sinConversacion: return "sin_conversacion"
        case .envioSinReferencia: return "sin_referencia"
        case .noCoincide: return "no_coincide"
        }
    }
}

/// Las comprobaciones, en los tres puntos donde se decide algo sobre «de quién es esto».
public enum ConsistencyCheck {

    /// **Antes de mandar.** Es donde estaba el bug: con `visible` presente y `reference` en nil, el mensaje no
    /// se podía mandar; y con una `reference` que no es la de la conversación visible, se iba a otra.
    public static func send(reference: String?, visible: String?, instancia: String?) -> ConsistencyVerdict {
        if let visible, reference == nil {
            return .envioSinReferencia(visible: visible)
        }
        return compare(reference: reference, visible: visible, instancia: instancia)
    }

    /// **Al enganchar una instancia.** La instancia que se engancha tiene que ser la de la conversación
    /// visible; si es la de otra —aunque esté viva a propósito—, sus eventos se dibujarían acá.
    public static func bind(reference: String?, visible: String?, instancia: String?) -> ConsistencyVerdict {
        compare(reference: reference, visible: visible, instancia: instancia)
    }

    /// **Al abrir o cambiar de conversación.** La referencia tiene que ser la de la que se está abriendo.
    public static func open(reference: String?, visible: String?) -> ConsistencyVerdict {
        compare(reference: reference, visible: visible, instancia: nil)
    }

    private static func compare(reference: String?, visible: String?, instancia: String?) -> ConsistencyVerdict {
        // Nada abierto y nada referenciado: no hay nada que decidir.
        if visible == nil && reference == nil { return .sinConversacion }
        var discrepancias = false
        if let visible, let reference, visible != reference { discrepancias = true }
        // Solo se compara la instancia cuando hay referencia con qué compararla: una conversación nueva en
        // preparación se identifica por su uuid y su instancia por la clave del pool, así que la comparación
        // sería entre dos cosas distintas y daría un falso positivo.
        if let instancia, let reference, instancia != reference { discrepancias = true }
        if discrepancias { return .noCoincide(ref: reference, visible: visible, instancia: instancia) }
        return .ok(clave: reference ?? visible ?? "")
    }
}

extension Log {
    /// Registra un veredicto. Una violación queda como **`fault`**, que en el vocabulario de `os.Logger`
    /// significa exactamente esto: *«esto no debería poder pasar»*.
    public static func check(_ verdict: ConsistencyVerdict) {
        record(verdict.event, [
            (.motivo, .word(verdict.motivo)),
        ])
    }

    /// Registra un veredicto con las tres claves, recortadas.
    public static func check(_ verdict: ConsistencyVerdict,
                             reference: String?, visible: String?, instancia: String?) {
        record(verdict.event, [
            (.clave, .key(reference)),
            (.visible, .key(visible)),
            (.instancia, .key(instancia)),
            (.motivo, .word(verdict.motivo)),
        ])
    }
}
