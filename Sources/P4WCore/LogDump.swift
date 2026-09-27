import Foundation
import OSLog

/// Sacar el registro del Mac: los últimos minutos de **lo nuestro**, en un archivo que se puede mandar.
///
/// Está en el núcleo porque lo usan las dos puertas: el flag `--logs` (para leerlos desde la terminal) y el
/// botón «Guardar diagnóstico…» (para que Jorge los pueda mandar cuando algo salga mal).
///
/// **Dos trampas que documenta la práctica** y que están resueltas acá:
///
/// 1. El filtro de tiempo es solo un **punto de partida**: `getEntries` no acepta un «hasta», así que la
///    iteración sigue hasta el final del registro. Sin un corte por cantidad, esto puede crecer sin control.
/// 2. La iteración **en reversa no es confiable**. Así que se junta en orden y se limita al final.
public enum LogDump {

    /// Una línea ya legible: fecha, categoría, nivel y el mensaje (que ya viene con forma, nunca con contenido).
    public struct Line: Sendable {
        public let date: Date
        public let category: String
        public let level: String
        public let message: String

        public var text: String {
            let formato = DateFormatter()
            formato.dateFormat = "HH:mm:ss.SSS"
            return "\(formato.string(from: date)) [\(category)] \(level) \(message)"
        }
    }

    /// Los últimos `minutes` minutos de nuestro subsistema, con un techo de líneas.
    public static func recent(minutes: Int = 15, limit: Int = 4_000) -> [Line] {
        do {
            let store = try OSLogStore.local()
            let desde = store.position(timeIntervalSinceEnd: -Double(max(1, minutes)) * 60)
            let filtro = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let entradas = try store.getEntries(with: [], at: desde, matching: filtro)

            var lineas: [Line] = []
            for entrada in entradas {
                // El corte por cantidad, que es lo que evita que esto se desborde.
                if lineas.count >= limit { break }
                guard let log = entrada as? OSLogEntryLog else { continue }
                lineas.append(Line(date: log.date,
                                   category: log.category,
                                   level: nombre(log.level),
                                   message: log.composedMessage))
            }
            return lineas
        } catch {
            // Que no se puedan leer los logs no puede romper nada: se dice y se sigue.
            return [Line(date: Date(), category: "consistencia", level: "error",
                         message: "no se pudieron leer los registros: \(error.localizedDescription)")]
        }
    }

    /// El texto completo: un encabezado con el entorno (sin contenido) y las líneas.
    public static func text(minutes: Int = 15, limit: Int = 4_000, entorno: String) -> String {
        var salida = """
        P4W — diagnóstico
        \(entorno)

        Registros de los últimos \(minutes) minutos (subsistema \(Log.subsystem)).
        **No incluye el texto de ninguna conversación**: el registro guarda formas y conteos, no contenido.

        """
        for linea in recent(minutes: minutes, limit: limit) {
            salida += linea.text + "\n"
        }
        return salida
    }

    /// Escribe el diagnóstico en un archivo y devuelve dónde quedó.
    @discardableResult
    public static func write(minutes: Int = 15, entorno: String, to url: URL) throws -> URL {
        let contenido = text(minutes: minutes, entorno: entorno)
        try contenido.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// El nivel, en una palabra corta. `OSLogEntryLog.Level` distingue más casos de los que usamos.
    private static func nombre(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "aviso"
        case .error: return "error"
        case .fault: return "FALLA"
        default: return "?"
        }
    }
}
