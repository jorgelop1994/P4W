import Foundation

/// Una versión publicada, comparable.
///
/// Se comparan los números, no el texto: `0.10.0` es más nueva que `0.9.0`, y comparar como texto diría lo
/// contrario. Es el error clásico de los avisos de actualización, y por eso la comparación está acá, aislada
/// y con verificaciones propias.
public struct ReleaseVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let numbers: [Int]
    /// Lo que venía después del guion (`1.0.0-beta.2`). Un sufijo significa que no es una versión estable.
    public let suffix: String?

    /// Acepta `v0.1.0`, `0.1.0`, `0.1` y `0.1.0-beta.1`. Devuelve `nil` si no se puede leer.
    public init?(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("v") || clean.hasPrefix("V") { clean.removeFirst() }
        guard !clean.isEmpty else { return nil }

        let parts = clean.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numeric = String(parts.first ?? "")
        suffix = parts.count > 1 ? String(parts[1]) : nil

        let pieces = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard let value = Int(piece) else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
    }

    public var isPrerelease: Bool { suffix != nil }

    /// Igualdad **coherente con el orden**: dos versiones son la misma si ninguna es menor que la otra.
    ///
    /// El `==` sintetizado compara los arreglos de números, así que `1.0` y `1.0.0` daban distinto mientras
    /// el orden los consideraba iguales. Esa incoherencia se vería en el aviso: descartar la `0.2.0` no
    /// reconocería como la misma a una publicación etiquetada `0.2.0.0`, y volvería a avisar de lo mismo.
    public static func == (left: ReleaseVersion, right: ReleaseVersion) -> Bool {
        !(left < right) && !(right < left)
    }

    /// La comparación, número por número. Los componentes que faltan valen cero: `1.0` y `1.0.0` son la
    /// misma versión.
    public static func < (left: ReleaseVersion, right: ReleaseVersion) -> Bool {
        let count = max(left.numbers.count, right.numbers.count)
        for index in 0..<count {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (suffix.map { "-\($0)" } ?? "")
    }
}

/// Novedades de una versión publicada.
public struct UpdateInfo: Sendable, Equatable {
    public let version: ReleaseVersion
    /// El `.dmg`, si el release lo trae. Si no, la página del release.
    public let downloadURL: URL
    public let releaseURL: URL?
    public let name: String?

    public init(version: ReleaseVersion, downloadURL: URL, releaseURL: URL? = nil, name: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
        self.name = name
    }
}

/// Consulta si hay una versión más nueva, sin servidor propio.
///
/// **Nada de esto puede romper la app.** Un aviso de novedad es opcional: si la consulta falla —sin
/// internet, GitHub caído, una respuesta rara— el resultado es "no sé", y "no sé" **no se muestra**. Es la
/// regla de fallar abierto, y está implementada acá y verificada.
public enum UpdateCheck {

    /// El repositorio del que se baja. Público, así que la consulta no necesita credenciales.
    public static let repository = "jorgelop1994/P4W"

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public enum Outcome: Sendable, Equatable {
        case upToDate(current: ReleaseVersion)
        case available(UpdateInfo)
        /// No se pudo saber. **No se muestra nada**: una novedad opcional no puede convertirse en un error.
        case unknown(reason: String)

        public var update: UpdateInfo? {
            if case .available(let info) = self { return info }
            return nil
        }
    }

    /// Decide a partir de la respuesta cruda de la API de GitHub.
    ///
    /// Está separada de la consulta a propósito: así se verifica con **respuestas guardadas** en vez de
    /// depender de internet y de que hoy exista un release nuevo.
    public static func decode(_ data: Data, current: ReleaseVersion) -> Outcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown(reason: "la respuesta no es JSON")
        }
        guard let tag = object["tag_name"] as? String else {
            return .unknown(reason: "la respuesta no trae tag_name")
        }
        guard let remote = ReleaseVersion(tag) else {
            return .unknown(reason: "no pude leer la versión «\(tag)»")
        }
        // Una versión con sufijo es previa al lanzamiento. No se ofrece: nadie quiere que la app le avise
        // de una beta que no pidió.
        guard !remote.isPrerelease else {
            return .upToDate(current: current)
        }
        guard remote > current else {
            return .upToDate(current: current)
        }

        let releaseURL = (object["html_url"] as? String).flatMap(URL.init(string:))
        let assets = object["assets"] as? [[String: Any]] ?? []
        // El `.dmg` primero: es lo que la persona va a querer. Si el release no lo trae, la página.
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let download = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)) ?? releaseURL
        guard let download else {
            return .unknown(reason: "el release no trae nada que se pueda descargar")
        }
        return .available(UpdateInfo(
            version: remote,
            downloadURL: download,
            releaseURL: releaseURL,
            name: object["name"] as? String
        ))
    }

    /// Consulta de verdad. Es lo único que sale a la red, y lo hace en segundo plano.
    public static func latest(current: ReleaseVersion, session: URLSession = .shared) async -> Outcome {
        do {
            var request = URLRequest(url: latestReleaseURL)
            request.timeoutInterval = 10
            // La API de GitHub devuelve `application/json` a quien lo pida; sin esto contesta texto.
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unknown(reason: "respuesta sin estado")
            }
            guard http.statusCode == 200 else {
                return .unknown(reason: "GitHub contestó \(http.statusCode)")
            }
            return decode(data, current: current)
        } catch {
            return .unknown(reason: "\(error.localizedDescription)")
        }
    }

    /// Cuánto tiempo se espera entre consultas: **una vez por día**, que es lo que recomienda la práctica
    /// para no golpear la API ni molestar. Se guarda la fecha de la última consulta.
    public static let minimumInterval: TimeInterval = 24 * 60 * 60

    public static func shouldCheck(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minimumInterval
    }
}

/// Cuándo se muestra el aviso. Son las reglas investigadas, juntas y en un solo lugar, porque son una
/// decisión y no un detalle de la vista.
public enum UpdateNotice {

    /// - Parameters:
    ///   - outcome: el resultado de la consulta. `nil` = todavía no se consultó.
    ///   - dismissedVersion: la versión que la persona descartó, si descartó alguna.
    ///   - piIsWorking: si Pi tiene un run en curso.
    public static func shouldShow(outcome: UpdateCheck.Outcome?, dismissedVersion: String?,
                                  piIsWorking: Bool) -> Bool {
        // 1. Solo cuando hay algo nuevo. Ni "al día" ni "no se pudo consultar" se muestran: no hay nada
        //    que hacer con esa información, y una novedad opcional no puede convertirse en un error.
        guard let update = outcome?.update else { return false }
        // 2. **Nunca mientras Pi trabaja.** Es el momento en que la persona está esperando otra cosa, y
        //    tapar eso con un aviso de versión es exactamente lo que no hay que hacer.
        guard !piIsWorking else { return false }
        // 3. Lo descartado se recuerda **por versión**: descartar la 0.2.0 no silencia la 0.3.0.
        if let dismissedVersion, ReleaseVersion(dismissedVersion) == update.version { return false }
        return true
    }
}
