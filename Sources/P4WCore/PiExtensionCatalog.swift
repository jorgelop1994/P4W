import Foundation

/// Catálogo de extensiones de Pi instaladas, **leído de los propios paquetes**.
///
/// No hay lista escrita a mano: cada paquete declara sus puntos de entrada en su `package.json`:
///
/// ```json
/// "pi": { "extensions": ["./dist"], "appliesToModels": ["deepseek-*", "deepseek"] }
/// ```
///
/// Con `--no-extensions` Pi apaga el descubrimiento, pero **las rutas `-e` explícitas siguen cargando**.
/// Eso es lo que permite un perfil liviano que igual conserve extensiones puntuales — por ejemplo el
/// caché de prefijo, que es lo que hace que la entrada se pague cacheada en vez de completa.
public struct PiExtension: Sendable, Identifiable, Equatable {
    /// Nombre del paquete o del archivo suelto. Es lo que se muestra.
    public let name: String
    public let version: String?
    /// Rutas absolutas que se le pasan a `pi` con `-e`. Puede ser un archivo o un directorio.
    public let entryPoints: [String]
    /// Modelos a los que aplica, si el paquete lo declara. Vacío = todos.
    public let appliesToModels: [String]
    /// De dónde salió: paquete npm o archivo suelto en el directorio de extensiones.
    public let origin: Origin

    public enum Origin: String, Sendable {
        case package
        case loose
    }

    public var id: String { name }

    /// Etiqueta corta para la interfaz.
    public var shortName: String {
        name.hasPrefix("@") ? String(name.split(separator: "/").last ?? "") : name
    }

    /// Aplica a un modelo concreto? Un paquete sin `appliesToModels` aplica a todos.
    public func applies(toModel modelID: String) -> Bool {
        guard !appliesToModels.isEmpty else { return true }
        let lowered = modelID.lowercased()
        return appliesToModels.contains { pattern in
            let trimmed = pattern.lowercased().replacingOccurrences(of: "*", with: "")
            return trimmed.isEmpty || lowered.contains(trimmed)
        }
    }
}

public enum PiExtensionCatalog {

    /// Directorios donde Pi instala paquetes y donde guarda extensiones sueltas.
    public static var searchRoots: [String] {
        [
            NSString(string: "~/.pi/agent/npm/node_modules").expandingTildeInPath,
            NSString(string: "~/.pi/agent/extensions").expandingTildeInPath,
        ]
    }

    /// Recorre lo instalado y arma el catálogo. Lo que no se puede leer se saltea en silencio: un
    /// paquete roto no puede impedir que aparezcan los demás.
    public static func discover(roots: [String] = searchRoots) -> [PiExtension] {
        var found: [PiExtension] = []
        let manager = FileManager.default

        for root in roots {
            guard let entries = try? manager.contentsOfDirectory(atPath: root) else { continue }

            for entry in entries where !entry.hasPrefix(".") {
                let path = "\(root)/\(entry)"

                // Paquete con scope: @scope/nombre
                if entry.hasPrefix("@"), let scoped = try? manager.contentsOfDirectory(atPath: path) {
                    for name in scoped where !name.hasPrefix(".") {
                        if let extensionEntry = read(packageAt: "\(path)/\(name)", name: "\(entry)/\(name)") {
                            found.append(extensionEntry)
                        }
                    }
                    continue
                }

                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    // Un paquete instalado por npm.
                    if let extensionEntry = read(packageAt: path, name: entry) {
                        found.append(extensionEntry)
                    }
                } else if entry.hasSuffix(".ts") || entry.hasSuffix(".js") {
                    // Archivo suelto en el directorio de extensiones.
                    found.append(PiExtension(
                        name: entry,
                        version: nil,
                        entryPoints: [path],
                        appliesToModels: [],
                        origin: .loose
                    ))
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Lee `pi.extensions` de un `package.json`. Sin esa clave, el paquete no aporta extensiones.
    private static func read(packageAt directory: String, name: String) -> PiExtension? {
        let manifest = "\(directory)/package.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pi = object["pi"] as? [String: Any] else { return nil }

        // `extensions` puede venir como lista de rutas relativas al paquete.
        let declared = pi["extensions"] as? [String] ?? []
        guard !declared.isEmpty else { return nil }

        let manager = FileManager.default
        let entryPoints = declared
            .map { $0.hasPrefix("/") ? $0 : "\(directory)/\($0)" }
            .filter { manager.fileExists(atPath: $0) }
        guard !entryPoints.isEmpty else { return nil }

        return PiExtension(
            name: name,
            version: object["version"] as? String,
            entryPoints: entryPoints,
            appliesToModels: pi["appliesToModels"] as? [String] ?? [],
            origin: .package
        )
    }
}
