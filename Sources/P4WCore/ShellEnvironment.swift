import Foundation

/// Resuelve el entorno real del usuario y la ubicación de `pi` y `node`.
///
/// Motivo: `pi` es un shim `#!/usr/bin/env node`, y una app lanzada desde Finder/Dock
/// NO hereda el PATH del shell (macOS le da solo `/usr/bin:/bin:/usr/sbin:/sbin`).
/// Sin esto, P4W arranca y falla al lanzar Pi sin decir por qué.
public struct ShellEnvironment: Sendable {

    /// PATH final para inyectar en el proceso hijo.
    public let path: String

    /// Ruta absoluta de `pi`, si se encontró.
    public let piExecutable: URL?

    /// Ruta absoluta de `node`, si se encontró. Necesario porque `pi` es un shim de `env node`.
    public let nodeExecutable: URL?

    /// De dónde salió la resolución. Para diagnóstico en la UI.
    public let diagnostic: String

    /// Prefijos típicos: Apple Silicon primero, Intel después. Nunca hardcodear uno solo.
    public static let knownBinDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        NSString(string: "~/.local/bin").expandingTildeInPath,
        NSString(string: "~/bin").expandingTildeInPath,
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// Shell de login del usuario, leído de passwd (no de `$SHELL`, que puede no estar seteado).
    public static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty { return value }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public static func resolve() -> ShellEnvironment {
        var notes: [String] = []
        let shell = loginShell
        notes.append("shell=\(shell)")

        // 1. PATH del shell de login. `-lc` lee .zprofile/.zshenv (donde vive `brew shellenv`).
        var loginPath = run(shell, ["-lc", "printf %s \"$PATH\""], timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 2. Fallback: shell interactivo, por si el PATH se arma en .zshrc.
        if loginPath.isEmpty {
            loginPath = run(shell, ["-ilc", "printf %s \"$PATH\""], timeout: 5)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            notes.append("PATH desde shell interactivo")
        } else {
            notes.append("PATH desde shell de login")
        }

        if loginPath.isEmpty {
            notes.append("PATH del shell vacío → usando prefijos conocidos")
        }

        // 3. Resolver binarios. Primero con el PATH del login shell, después por prefijos.
        let pi = locate("pi", usingShell: shell, loginPath: loginPath)
        let node = locate("node", usingShell: shell, loginPath: loginPath)

        // 4. PATH final: el del shell + el directorio de pi y node al frente + prefijos conocidos.
        var seen = Set<String>()
        var components: [String] = []
        func add(_ dir: String?) {
            guard let dir, !dir.isEmpty, !seen.contains(dir) else { return }
            seen.insert(dir)
            components.append(dir)
        }
        add(pi?.deletingLastPathComponent().path)
        add(node?.deletingLastPathComponent().path)
        for component in loginPath.split(separator: ":") { add(String(component)) }
        for dir in knownBinDirectories { add(dir) }

        notes.append(pi == nil ? "pi NO encontrado" : "pi=\(pi!.path)")
        notes.append(node == nil ? "node NO encontrado" : "node=\(node!.path)")

        return ShellEnvironment(
            path: components.joined(separator: ":"),
            piExecutable: pi,
            nodeExecutable: node,
            diagnostic: notes.joined(separator: " | ")
        )
    }

    /// Busca un ejecutable por nombre: primero `command -v` en el shell, después prefijos conocidos.
    private static func locate(_ name: String, usingShell shell: String, loginPath: String) -> URL? {
        for args in [["-lc", "command -v \(name)"], ["-ilc", "command -v \(name)"]] {
            if let raw = run(shell, args, timeout: 5) {
                // Un shell interactivo puede imprimir banners; la ruta es la última línea válida.
                for line in raw.split(separator: "\n").reversed() {
                    let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasSuffix("/\(name)"), FileManager.default.isExecutableFile(atPath: candidate) {
                        return URL(fileURLWithPath: candidate)
                    }
                }
            }
        }
        let searchPath = loginPath.isEmpty ? knownBinDirectories.joined(separator: ":") : loginPath
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        for dir in knownBinDirectories {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Ejecuta el shell con timeout. Devuelve stdout, o nil si falló o expiró.
    private static func run(_ shell: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? nil
        guard let data, !data.isEmpty else { return process.terminationStatus == 0 ? "" : nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Entorno completo para el proceso hijo.
    public func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        for (key, value) in extra { env[key] = value }
        return env
    }
}
