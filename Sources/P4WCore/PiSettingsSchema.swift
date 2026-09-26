import Foundation

/// El esquema de configuración de Pi, **generado desde su propia documentación**.
///
/// No hay una lista escrita a mano. P4W encuentra `docs/settings.md` dentro del paquete de Pi que está
/// instalado y parsea sus tablas:
///
/// ```
/// | `defaultModel` | string | Automatic | Startup model ID. |
/// ```
///
/// La ventaja es concreta: si Pi agrega o cambia un ajuste, P4W lo muestra sin tocar una línea. Si el
/// formato del documento cambia y el parseo no encuentra nada, la vista de configuración lo dice y cae
/// a un editor de JSON crudo en vez de mostrar una pantalla vacía.
public enum PiSettingsSchema {

    public enum Kind: Equatable {
        case boolean
        case number
        case text
        case enumeration([String])
        /// Lista de textos (`string[]`). Se edita como líneas separadas.
        case textList
        /// Objeto libre: se muestra pero no se edita campo por campo en v1.
        case object
    }

    public struct Setting: Identifiable, Equatable {
        public let key: String
        public let kind: Kind
        public let defaultValue: String?
        public let help: String
        public let section: String

        public var id: String { key }
    }

    /// Encuentra `docs/settings.md` a partir del binario de `pi` que se va a usar.
    ///
    /// El binario es un enlace a `.../<paquete>/dist/bundle/cli.js`, así que el paquete está tres
    /// niveles arriba. Se prueban los candidatos en vez de asumir uno solo.
    public static func discoverDocPath(piExecutable: URL?) -> String? {
        var candidates: [String] = []
        if let executable = piExecutable {
            let real = URL(fileURLWithPath: executable.path).resolvingSymlinksInPath()
            var directory = real.deletingLastPathComponent()
            for _ in 0..<4 {
                candidates.append(directory.appendingPathComponent("docs/settings.md").path)
                directory = directory.deletingLastPathComponent()
            }
        }
        // Y por si el binario no dice nada, las ubicaciones típicas.
        candidates.append(contentsOf: [
            "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/docs/settings.md",
            "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/docs/settings.md",
            NSString(string: "~/.pi/agent/dist/docs/settings.md").expandingTildeInPath,
        ])
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Parsea las tablas del documento. Devuelve los ajustes en el orden en que aparecen.
    public static func parse(documentAt path: String) -> [Setting] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var settings: [Setting] = []
        var section = "General"
        var seen = Set<String>()

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## ") {
                section = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { continue }
            // En markdown, un `|` dentro de una celda se escribe `\|`. Sin tratarlo, las filas con
            // uniones (`"off" \| "final" \| "streaming"`) se partían de más y el tipo se perdía.
            let marker = "\u{1}"
            let unescaped = trimmed.replacingOccurrences(of: "\\|", with: marker)
            let cells = unescaped.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: marker, with: "|").trimmingCharacters(in: .whitespaces) }
            // | clave | tipo | default | descripción |
            guard cells.count >= 5 else { continue }
            let rawKey = cells[1]
            guard rawKey.hasPrefix("`"), rawKey.hasSuffix("`"), rawKey.count > 2 else { continue }
            let key = String(rawKey.dropFirst().dropLast())
            // La fila de guiones no es un ajuste.
            guard key.contains(where: { $0.isLetter }) else { continue }
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let rawType = cells[2]
            let rawDefault = cells[3]
            let help = cells[4]
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)

            settings.append(Setting(
                key: key,
                kind: kind(from: rawType),
                defaultValue: rawDefault == "None" || rawDefault.isEmpty ? nil
                    : rawDefault.replacingOccurrences(of: "*", with: ""),
                help: help,
                section: section
            ))
        }
        return settings
    }

    /// El tipo viene en markdown: a veces es simple (`boolean`) y a veces una unión
    /// (`` `"off" \| "final" \| "streaming"` ``). Se interpreta en vez de exigir un formato.
    static func kind(from rawType: String) -> Kind {
        let type = rawType.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)

        if type.contains("|") {
            // Unión: los literales entre comillas son las opciones; si aparecen boolean/number,
            // también son opciones válidas.
            var options: [String] = []
            for piece in type.split(separator: "|") {
                let value = piece.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") || value.hasPrefix("'") {
                    options.append(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                } else if value == "boolean" {
                    options.append(contentsOf: ["true", "false"])
                } else if value == "number" {
                    options.append("número")
                } else if value == "false" {
                    options.append("false")
                }
            }
            if !options.isEmpty { return .enumeration(options) }
        }
        if type == "boolean" { return .boolean }
        if type == "number" { return .number }
        if type == "object" || type.hasPrefix("Record") { return .object }
        if type.contains("[]") || type == "array" { return .textList }
        return .text
    }
}
