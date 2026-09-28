import Foundation
import os

// MARK: - Qué se registra, con qué nivel y con qué forma

/// El registro de lo que pasa, con las decisiones **en tipos puros**.
///
/// Nació de un problema concreto: tres bugs de la misma familia —*«¿de qué conversación es esto?»*— se
/// encontraron **leyendo código**, y ninguno era visible en pantalla. Los tres se habrían visto en una línea de
/// log. Pero un log mal hecho es peor que ninguno, así que las reglas están acá y no en la disciplina de quien
/// escribe la llamada.
///
/// **La regla central: contenido nunca, forma siempre.** El texto de los mensajes, los prompts y la salida de Pi
/// no se registran — y no por disciplina, sino porque **no hay forma de hacerlo**: `LogValue` solo se puede
/// construir con las fábricas de abajo, y ninguna acepta texto libre de la persona.
public enum Log {

    /// El subsistema: el bundle id de la app. Es lo que permite filtrar **lo nuestro** entre todo lo que escribe
    /// el sistema, y es lo que usa el volcado de diagnóstico.
    public static let subsystem = "dev.p4w.app"

    /// **La línea, como texto, sin escribirla.** Está separada de `record` para que se pueda verificar: una
    /// comprobación arma la peor línea posible y revisa que no se haya filtrado nada. Si la composición
    /// viviera adentro del `record`, no habría forma de mirarla sin capturar `os_log`.
    public static func compose(_ event: LogEvent, _ values: [(LogField, LogValue)] = []) -> String {
        var line = event.rawValue
        for (field, value) in values {
            line += " \(field.rawValue)=\(value.text)"
        }
        return line
    }

    /// Escribe una línea. Los valores vienen ya con forma (`LogValue`), nunca con contenido.
    public static func record(_ event: LogEvent, _ values: [(LogField, LogValue)] = []) {
        let rule = LogPolicy.rule(for: event)
        let logger = Logger(subsystem: subsystem, category: rule.category.rawValue)
        let line = compose(event, values)
        switch rule.level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        case .fault: logger.fault("\(line, privacy: .public)")
        }
    }

    /// Atajo para el caso de un solo valor, que es la mitad de las llamadas.
    public static func record(_ event: LogEvent, _ field: LogField, _ value: LogValue) {
        record(event, [(field, value)])
    }
}

/// Niveles, en el vocabulario de `os.Logger` y con el significado que Apple le da a cada uno.
///
/// Hay dos datos de la documentación de Apple que cambiaron este diseño:
///
/// 1. **`debug` solo se registra si una herramienta lo pide.** Es el nivel equivocado para algo que después
///    tiene que **estar**: si la línea tiene que aparecer en un diagnóstico que se manda, no puede ser `debug`.
/// 2. **`fault` significa «esto es un bug en el código»**, para dar contexto a una suposición violada. No es un
///    «error grave»: es un «esto no debería poder pasar».
///
/// Y el tercero: el sistema considera **privadas** a las cadenas dinámicas y no las recolecta. Eso es una red de
/// seguridad, pero acá no se depende de ella: directamente no se construyen.
public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    /// Detalle finísimo: cada evento RPC, cada decisión de agrupación. Solo para cuando se está mirando.
    case debug
    /// El recorrido. Apple advierte que vive poco (buffer en memoria), así que **no** se usa para lo que tiene
    /// que estar después.
    case info
    /// Los hitos que alguien podría necesitar mandar. Es el nivel «default» de `os_log`, que se guarda siempre.
    case notice
    /// Algo falló y se puede contarnos.
    case error
    /// Una **suposición violada**. El detector de bugs.
    case fault

    private var orden: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .error: return 3
        case .fault: return 4
        }
    }

    public static func < (uno: LogLevel, otro: LogLevel) -> Bool { uno.orden < otro.orden }
}

/// Las categorías son las costuras que el código ya tiene, no una taxonomía inventada.
public enum LogCategory: String, Sendable, CaseIterable {
    case ciclo            // arranque, cierre, permisos, dependencias
    case supervisor       // adquirir, liberar, reciclar instancias
    case conversacion     // abrir, cambiar, cerrar, pertenencia a spaces
    case envio            // qué se manda y **a quién**
    case rpc              // eventos de Pi: tipo y tamaño, nunca contenido
    case indice           // indexado, reindexado, fallos
    case avisos           // por qué sonó o no sonó
    case actualizacion    // la consulta de versión nueva
    case consistencia     // las suposiciones sobre «de quién es esto»
}

/// Un evento con nombre propio. Cada uno tiene **una** fila en la tabla: no se decide el nivel en la llamada.
public enum LogEvent: String, Sendable, CaseIterable {
    // Ciclo
    case appArranco = "ciclo.arranco"
    case appCerro = "ciclo.cierro"
    case dependencias = "ciclo.dependencias"
    case permisoAvisos = "ciclo.permiso_avisos"
    case permisoGrabacion = "ciclo.permiso_grabacion"

    // Supervisor
    case instanciaAdquirida = "supervisor.adquirida"
    case instanciaLiberada = "supervisor.liberada"
    case instanciaReciclada = "supervisor.reciclada"
    case instanciaReclavada = "supervisor.reclavada"
    case instanciaRechazada = "supervisor.rechazada"
    case instanciaNoDisponible = "supervisor.no_disponible"

    // Conversación
    case conversacionAbierta = "conversacion.abierta"
    case conversacionNueva = "conversacion.nueva"
    case conversacionCerrada = "conversacion.cerrada"
    case spaceAsignado = "conversacion.space"
    case spacesPodados = "conversacion.podados"

    // Envío
    case envioPedido = "envio.pedido"
    case envioEncolado = "envio.encolado"
    case envioConfirmado = "envio.confirmado"
    case borradorOlvidado = "envio.borrador_olvidado"
    /// **El bug que reportó Jorge.** Mandar sin referencia, o con la de otra conversación.
    case envioSinReferencia = "envio.sin_referencia"

    // RPC
    case rpcEvento = "rpc.evento"
    case rpcDialogo = "rpc.dialogo"
    case rpcFallo = "rpc.fallo"

    // Índice
    case indiceReconstruido = "indice.reconstruido"
    case indiceIncremental = "indice.incremental"
    case indiceFallo = "indice.fallo"

    // Avisos
    case avisoEmitido = "avisos.emitido"
    case avisoSilenciado = "avisos.silenciado"

    // Actualización
    case actualizacionConsultada = "actualizacion.consultada"
    case actualizacionFallo = "actualizacion.fallo"

    // Consistencia
    case consistenciaOk = "consistencia.ok"
    case consistenciaRota = "consistencia.rota"
}

/// Los campos que se pueden registrar. Es una lista **cerrada** a propósito: no hay un campo «contenido».
public enum LogField: String, Sendable, CaseIterable {
    case clave        // identidad de una conversación, recortada
    case visible      // la conversación que se está mirando, recortada
    case instancia    // la instancia viva, recortada
    case conteo
    case milisegundos
    case tipo         // vocabulario propio: estado, tipo de evento, tipo de diálogo
    case largo        // el tamaño de algo, no su contenido
    case version
    case permiso
    case motivo       // vocabulario propio, nunca texto de la persona
    case archivo      // el nombre del archivo: la única pieza legible a propósito
    case huella       // una firma corta de algo, sin el algo
}

/// Una fila de la tabla: nivel, categoría y **qué campos** se registran.
public struct LogRule: Sendable {
    public let level: LogLevel
    public let category: LogCategory
    public let fields: [LogField]
}

/// La tabla, completa y verificable.
///
/// El criterio de cada nivel salió de la documentación de Apple (ver `LogLevel`): `fault` para suposiciones
/// violadas, `notice` para los hitos que tienen que estar después, `info` para el recorrido, `debug` para el
/// detalle que solo importa mientras se mira.
public enum LogPolicy {

    /// **La tabla es data, no un `switch`.** Un `switch` de cuarenta casos es complejo de leer y no se puede
    /// recorrer; un diccionario sí, y eso permite **verificar que no falte ninguno** (lo que un `switch` daba
    /// gratis por exhaustividad se recupera con una comprobación explícita, y encima deja de ser silencioso).
    public static let table: [LogEvent: LogRule] = [
        // Lo que tiene que estar **después** de que pase algo: `notice`, que es el único nivel que el sistema
        // guarda siempre.
        .appArranco: .init(level: .notice, category: .ciclo, fields: [.version, .conteo]),
        .appCerro: .init(level: .notice, category: .ciclo, fields: [.motivo]),
        .dependencias: .init(level: .notice, category: .ciclo, fields: [.conteo, .motivo]),
        .permisoAvisos: .init(level: .notice, category: .ciclo, fields: [.permiso]),
        .permisoGrabacion: .init(level: .notice, category: .ciclo, fields: [.permiso]),
        .instanciaReciclada: .init(level: .notice, category: .supervisor, fields: [.clave, .motivo]),
        // El cambio de identidad de una conversación nueva cuando Pi le escribe el archivo: es un hito del
        // recorrido, y sin él la app no reconocía su propia instancia.
        .instanciaReclavada: .init(level: .notice, category: .supervisor, fields: [.clave, .archivo]),
        .conversacionAbierta: .init(level: .notice, category: .conversacion, fields: [.clave, .archivo]),
        .conversacionNueva: .init(level: .notice, category: .conversacion, fields: [.clave]),
        .envioPedido: .init(level: .notice, category: .envio, fields: [.clave, .largo]),
        .avisoEmitido: .init(level: .notice, category: .avisos, fields: [.clave, .tipo]),
        .indiceReconstruido: .init(level: .notice, category: .indice, fields: [.conteo, .milisegundos]),

        // El recorrido: `info`.
        .instanciaAdquirida: .init(level: .info, category: .supervisor, fields: [.clave, .tipo, .milisegundos]),
        .instanciaLiberada: .init(level: .info, category: .supervisor, fields: [.clave, .milisegundos]),
        .instanciaRechazada: .init(level: .info, category: .supervisor, fields: [.clave, .motivo]),
        .instanciaNoDisponible: .init(level: .info, category: .supervisor, fields: [.clave, .motivo]),
        .conversacionCerrada: .init(level: .info, category: .conversacion, fields: [.clave]),
        .spaceAsignado: .init(level: .info, category: .conversacion, fields: [.clave, .tipo]),
        .spacesPodados: .init(level: .info, category: .conversacion, fields: [.conteo]),
        .envioEncolado: .init(level: .info, category: .envio, fields: [.clave, .tipo]),
        .envioConfirmado: .init(level: .info, category: .envio, fields: [.clave]),
        .borradorOlvidado: .init(level: .info, category: .envio, fields: [.clave]),
        .rpcDialogo: .init(level: .info, category: .rpc, fields: [.clave, .tipo]),
        .indiceIncremental: .init(level: .info, category: .indice, fields: [.conteo, .milisegundos]),
        .avisoSilenciado: .init(level: .info, category: .avisos, fields: [.clave, .motivo]),
        .actualizacionConsultada: .init(level: .info, category: .actualizacion, fields: [.version]),

        // El detalle finísimo: `debug`, que **solo se registra cuando una herramienta lo pide**. Por eso nada
        // que tenga que estar después puede vivir acá.
        .rpcEvento: .init(level: .debug, category: .rpc, fields: [.tipo, .largo]),

        // Lo que falló y se puede contarnos.
        .rpcFallo: .init(level: .error, category: .rpc, fields: [.clave, .motivo]),
        .indiceFallo: .init(level: .error, category: .indice, fields: [.motivo]),
        .actualizacionFallo: .init(level: .error, category: .actualizacion, fields: [.motivo]),

        // **Suposiciones violadas**: «esto no debería poder pasar».
        .envioSinReferencia: .init(level: .fault, category: .envio, fields: [.clave, .visible, .motivo]),
        .consistenciaRota: .init(level: .fault, category: .consistencia, fields: [.clave, .visible, .instancia]),
        .consistenciaOk: .init(level: .debug, category: .consistencia, fields: [.clave, .visible, .instancia]),
    ]

    /// La fila de un evento. Si falta, se registra como **fault** en vez de callarse: una tabla incompleta es
    /// un bug, no un detalle.
    public static func rule(for event: LogEvent) -> LogRule {
        table[event] ?? LogRule(level: .fault, category: .consistencia, fields: [.motivo])
    }

    /// Si un evento quedó sin fila. Lo usa la verificación: **todos** tienen que estar.
    public static func missingRows() -> [LogEvent] {
        LogEvent.allCases.filter { table[$0] == nil }
    }

    /// Todos los campos que la tabla puede pedir. La verificación comprueba que **ninguno** sea contenido.
    public static var allFieldsInUse: Set<LogField> {
        Set(table.values.flatMap(\.fields))
    }
}

/// Un valor ya con forma. **Solo se construye con estas fábricas**, y ninguna acepta texto de la persona: eso es
/// lo que hace que «contenido nunca» sea un hecho del tipo y no una promesa.
public struct LogValue: Sendable, Equatable {
    public let text: String
    private init(_ text: String) { self.text = text }

    public static func number(_ valor: Int) -> LogValue { LogValue(String(valor)) }
    public static func ms(_ milliseconds: Int) -> LogValue { LogValue("\(milliseconds)ms") }
    public static func flag(_ bandera: Bool) -> LogValue { LogValue(bandera ? "sí" : "no") }

    /// Identidad de una conversación: **una huella**, no un recorte.
    ///
    /// Recortar era una fuga, y la encontró la propia verificación: `key("mi contraseña es hunter2")` mostraba
    /// `…hunter2`, porque los últimos ocho caracteres de algo corto **son** ese algo. Una huella permite lo
    /// único que hace falta —que dos líneas digan si son de la misma conversación— y no deja ver nada.
    public static func key(_ key: String?) -> LogValue {
        guard let key, !key.isEmpty else { return LogValue("ninguna") }
        return LogValue("…" + LogRedactor.fingerprint(key))
    }

    /// Una palabra de **nuestro** vocabulario: un estado, un tipo de evento, un tipo de diálogo. Nunca algo que
    /// haya escrito la persona.
    public static func word(_ word: String) -> LogValue { LogValue(word) }

    /// La forma de algo, sin el algo: largo y una huella corta. Es la puerta para «pasó algo arbitrario».
    public static func shape(_ text: String) -> LogValue {
        LogValue("\(text.count)u·\(LogRedactor.fingerprint(text))")
    }

    /// El **nombre del archivo** de una conversación: la única pieza legible a propósito, para poder decir de
    /// qué se está hablando. Es un sello de tiempo con un uuid, así que no expone nada de nadie.
    public static func fileName(_ path: String) -> LogValue {
        LogValue((path as NSString).lastPathComponent)
    }

    public static let none = LogValue("—")
}

/// Las dos operaciones que permiten registrar «algo pasó» sin registrar el algo.
public enum LogRedactor {

    // Acá vivía `tail`, que recortaba los últimos ocho caracteres. Se fue: para un texto corto, el recorte
    // **es** el texto, y eso era una fuga. Ahora la identidad de una conversación se registra como huella.

    /// Una huella corta y estable (no criptográfica): sirve para comparar dos líneas, no para recuperar el texto.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt32 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return String(hash, radix: 16)
    }
}
