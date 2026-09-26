import Foundation
import P4WCore

// Fase 0 — sonda de integración.
//
// Verifica lo que puede romperse antes de escribir una sola línea de UI:
//   1. resolución de `pi` y `node` desde una app GUI (PATH por login shell)
//   2. spawn de `pi --mode rpc` con stdin abierto
//   3. framing JSONL estricto en LF
//   4. comandos y respuestas correlacionadas por id
//   5. RSS real y shutdown ordenado (rc 0 al cerrar stdin)
//
// Uso: p4w-probe [--profile lean|capabilities|full] [--] [args extra para pi]

let argv = Array(CommandLine.arguments.dropFirst())
var profile = "lean"
var promptText: String?
var extraPiArguments: [String] = []
var index = 0
while index < argv.count {
    let argument = argv[index]
    if argument == "--" {
        extraPiArguments.append(contentsOf: argv[(index + 1)...])
        break
    }
    if argument == "--profile", index + 1 < argv.count {
        profile = argv[index + 1]
        index += 2
        continue
    }
    if argument == "--prompt", index + 1 < argv.count {
        promptText = argv[index + 1]
        index += 2
        continue
    }
    extraPiArguments.append(argument)
    index += 1
}

let profiles: [String: [String]] = [
    // Mínimo absoluto: sin extensiones, skills ni plantillas. ~120 MB medidos.
    "lean": ["--no-extensions", "--no-skills", "--no-prompt-templates"],
    // Conserva extensiones/skills/plantillas (las capacidades que hay que reflejar)
    // pero apaga los subsistemas que arrancan procesos hijos.
    "capabilities": ["--no-lens", "--no-lsp", "--no-tests", "--no-opengrep", "--no-autofix"],
    // Todo activo, tal como lo usaría la TUI en esta máquina.
    "full": [],
]

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func line(_ text: String) {
    print(text)
    fflush(stdout)
}

line("── Fase 0 · sonda de integración P4W ──────────────────────────")

// ── 1. Entorno ────────────────────────────────────────────────────────────────
let environment = ShellEnvironment.resolve()
line("entorno   : \(environment.diagnostic)")
line("PATH hijo : \(environment.path.split(separator: ":").prefix(6).joined(separator: ":"))…")

guard let pi = environment.piExecutable else {
    line("FALLO     : no se encontró `pi`. La app GUI no puede lanzarlo sin resolverlo por login shell.")
    exit(2)
}

// ── 2. Spawn ──────────────────────────────────────────────────────────────────
guard let profileArguments = profiles[profile] else {
    line("FALLO     : perfil desconocido '\(profile)'. Usá lean | capabilities | full.")
    exit(2)
}

let instance = PiInstance(executable: pi, environment: environment)

let responses = ResponseStore()
instance.onRecord = { record in
    switch record {
    case .response(let id, let command, let success, let data, let error):
        responses.store(id: id, command: command, success: success, data: data, error: error)
    case .event(let type, let payload):
        // En Fase 0 solo interesan los eventos que prueban el framing.
        if type == "agent_settled" || type == "message_update" {
            log("evento    : \(type)")
        }
        _ = payload    case .unparseable(let raw):
        log("registro no parseable: \(raw.prefix(120))")
    }
}
instance.onStderr = { text in
    for entry in text.split(separator: "\n") where !entry.isEmpty {
        log("stderr    : \(entry)")
    }
}

var arguments = profileArguments + ["--mode", "rpc", "--no-session", "--offline"]
arguments.append(contentsOf: extraPiArguments)

line("perfil    : \(profile) → \(arguments.joined(separator: " "))")

do {
    try instance.start(arguments: arguments)
} catch {
    line("FALLO     : \(error)")
    exit(2)
}
line("pid       : \(instance.pid)")

// ── 3. Handshake ──────────────────────────────────────────────────────────────
func request(_ id: String, _ type: String, _ fields: [String: Any] = [:]) -> ResponseStore.Reply? {
    do {
        try instance.send(id: id, type: type, fields: fields)
    } catch {
        line("FALLO     : enviando \(type): \(error)")
        return nil
    }
    guard let reply = responses.await(id: id, timeout: 20) else {
        line("FALLO     : sin respuesta a \(type) (id \(id))")
        return nil
    }
    return reply
}

let started = Date()
guard let state = request("1", "get_state") else {
    _ = instance.shutdown()
    exit(1)
}
let handshake = Date().timeIntervalSince(started)
let data = state.data ?? [:]
line("handshake : \(String(format: "%.2f", handshake)) s")
if let model = data["model"] as? [String: Any] {
    line("modelo    : \(model["id"] as? String ?? "?") (\(model["provider"] as? String ?? "?"))")
}
line("thinking  : \(data["thinkingLevel"] as? String ?? "?")")
line("sesión    : \(data["sessionId"] as? String ?? "?")")
line("mensajes  : \(data["messageCount"] as? Int ?? 0)")
line("streaming : \(data["isStreaming"] as? Bool ?? false)")

// Capacidades visibles: lo que la UI debe generar en vez de hardcodear (§6).
if let levels = request("2", "get_available_thinking_levels") {
    let values = levels.data?["levels"] as? [String] ?? []
    line("niveles   : \(values.joined(separator: ", "))")
}
if let commands = request("3", "get_commands") {
    let list = commands.data?["commands"] as? [[String: Any]] ?? []
    var bySource: [String: Int] = [:]
    for entry in list {
        let source = entry["source"] as? String ?? "?"
        bySource[source, default: 0] += 1
    }
    let summary = bySource.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    line("comandos  : \(list.count) → \(summary.isEmpty ? "ninguno" : summary)")
}
if let stats = request("4", "get_session_stats"), let payload = stats.data {
    if let tokens = payload["tokens"] as? [String: Any] {
        line("tokens    : \(tokens)")
    }
}

// ── 3b. Prueba de streaming: ¿qué eventos llegan realmente? ────────────────────
if let promptText {
    line("")
    line("── prueba de streaming ──────────────────────────────────────")
    line("prompt    : \(promptText)")
    let collector = EventCollector()
    instance.onRecord = { record in
        if case .response(let id, let command, let success, let data, let error) = record {
            responses.store(id: id, command: command, success: success, data: data, error: error)
            return
        }
        if case .event(let type, let payload) = record {
            collector.record(type: type, payload: payload)
        }
    }
    do {
        try instance.send(RPCCommand.prompt(id: "prompt-1", message: promptText, streamingBehavior: nil))
    } catch {
        line("FALLO     : enviando prompt: \(error)")
    }
    // Esperar agent_settled (la señal real de "terminó"), con techo.
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
        if collector.settled { break }
        usleep(200_000)
    }
    collector.report(line: line)
}

// ── 4. Memoria y shutdown ─────────────────────────────────────────────────────
line("propia    : \(ProcessMetrics.megabytes(ProcessMetrics.footprint(pid: instance.pid))) (footprint)")
line("residente : \(ProcessMetrics.megabytes(ProcessMetrics.resident(pid: instance.pid))) (ps rss)")

let status = instance.shutdown()
line("shutdown  : \(status.map { "rc \($0)" } ?? "no terminó (se forzó terminate)")")

line("──────────────────────────────────────────────────────────────")
exit(status == 0 ? 0 : 1)

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Colecta qué tipos de evento llegan de verdad, y si traen contenido de pensamiento.
/// Es la evidencia que decide si la burbuja de Thinking puede mostrarse.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var eventCounts: [String: Int] = [:]
    private var assistantEventCounts: [String: Int] = [:]
    private var thinkingChars = 0
    private var thinkingSample = ""
    private var textChars = 0
    private var filtered = 0
    private var toolNames: Set<String> = []
    private var seenSettled = false

    var settled: Bool {
        lock.lock(); defer { lock.unlock() }
        return seenSettled
    }

    func record(type: String, payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        eventCounts[type, default: 0] += 1
        if type == "agent_settled" { seenSettled = true }
        guard type == "message_update",
              let inner = payload["assistantMessageEvent"] as? [String: Any],
              let innerType = inner["type"] as? String else { return }
        assistantEventCounts[innerType, default: 0] += 1
        switch innerType {
        case "thinking_delta":
            // Ojo: el delta puede venir como string o como objeto con .text
            let delta = (inner["delta"] as? String)
                ?? ((inner["delta"] as? [String: Any])?["text"] as? String)
                ?? ""
            thinkingChars += delta.count
            if thinkingSample.count < 160 { thinkingSample += delta }
        case "thinking_end":
            // El contenido autoritativo llega acá.
            let content = (inner["content"] as? String)
                ?? ((inner["content"] as? [String: Any])?["thinking"] as? String)
                ?? ""
            if content.count > thinkingChars { thinkingChars = content.count }
            if thinkingSample.isEmpty { thinkingSample = String(content.prefix(160)) }
        case "text_delta":
            textChars += (inner["delta"] as? String)?.count ?? 0
        default:
            break
        }
    }

    func recordTool(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        toolNames.insert(name)
    }

    func report(line: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let events = eventCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        line("eventos   : \(events.isEmpty ? "ninguno" : events)")
        let inner = assistantEventCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        line("  internos: \(inner.isEmpty ? "ninguno" : inner)")
        line("texto     : \(textChars) caracteres")
        line("thinking  : \(thinkingChars) caracteres"
             + (thinkingChars > 0 ? "  ← LA BURBUJA SE PUEDE MOSTRAR" : "  ← no hay nada que mostrar"))
        if !thinkingSample.isEmpty {
            let sample = thinkingSample.replacingOccurrences(of: "\n", with: " ⏎ ")
            line("  muestra : \(sample.prefix(150))…")
        }
    }
}

/// Correlaciona respuestas por id. El protocolo es asíncrono: no se puede asumir orden.
final class ResponseStore: @unchecked Sendable {
    struct Reply {
        let id: String?
        let command: String?
        let success: Bool
        let data: [String: Any]?
        let error: String?
    }

    private let condition = NSCondition()
    private var replies: [String: Reply] = [:]

    func store(id: String?, command: String?, success: Bool, data: [String: Any]?, error: String?) {
        guard let id else { return }
        condition.lock()
        replies[id] = Reply(id: id, command: command, success: success, data: data, error: error)
        condition.broadcast()
        condition.unlock()
    }

    func await(id: String, timeout: TimeInterval) -> Reply? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while replies[id] == nil {
            if Date() >= deadline { return nil }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
        return replies.removeValue(forKey: id)
    }
}
