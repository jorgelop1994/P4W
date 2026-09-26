import Foundation
import P4WCore

// Fase 1 — verificación del supervisor + reaper, sin UI.
//
// Prueba, contra Pi real, lo que el plan exige:
//   A. lanzar una sesión existente y recuperar su contexto (handshake)
//   B. máquina de estados derivada del stream, incluida una corrida con herramienta
//   C. NUNCA reciclar una instancia ocupada (regla de oro 3)
//   D. reciclar por inactividad y liberar memoria de verdad
//   E. despertar después del reciclado SIN perder la conversación
//   F. tope de instancias vivas con reciclado LRU
//   G. métricas honestas: memoria propia (footprint) vs residente

var failures = 0
var checks = 0

func line(_ text: String) {
    print(text)
    fflush(stdout)
}

func section(_ title: String) {
    line("")
    line("── \(title) " + String(repeating: "─", count: max(0, 58 - title.count)))
}

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    let mark = ok ? "✅" : "❌"
    line("\(mark) \(name)\(detail.isEmpty ? "" : "  → \(detail)")")
}

func poll(_ instance: ManagedInstance, until predicate: (InstanceState) -> Bool,
          timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(instance.state) { return true }
        usleep(120_000)
    }
    return predicate(instance.state)
}

// ── Preparación ───────────────────────────────────────────────────────────────

section("Preparación")

let environment = ShellEnvironment.resolve()
guard let pi = environment.piExecutable else {
    line("FALLO: no se encontró `pi`. \(environment.diagnostic)")
    exit(2)
}
line("pi        : \(pi.path)")

// Se trabaja sobre COPIAS: P4W nunca debe escribir una sesión real del usuario.
let sourceRoot = NSString(string: "~/.pi/agent/sessions").expandingTildeInPath
let candidates = (try? FileManager.default.contentsOfDirectory(atPath: sourceRoot)) ?? []
var sourceFiles: [String] = []
for dir in candidates.sorted() {
    let full = "\(sourceRoot)/\(dir)"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: full) else { continue }
    for file in files where file.hasSuffix(".jsonl") {
        sourceFiles.append("\(full)/\(file)")
    }
    if sourceFiles.count >= 3 { break }
}
guard sourceFiles.count >= 3 else {
    line("FALLO: hacen falta 3 sesiones para probar. Encontré \(sourceFiles.count).")
    exit(2)
}

let work = "\(NSTemporaryDirectory())p4w-phase1-\(UUID().uuidString.prefix(8))"
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
// Sin `try`: el cierre solo usa `try?` adentro.
let copies: [String] = sourceFiles.prefix(3).enumerated().map { index, source in
    let destination = "\(work)/session\(index).jsonl"
    try? FileManager.default.removeItem(atPath: destination)
    try? FileManager.default.copyItem(atPath: source, toPath: destination)
    return destination
}
line("sesiones  : \(copies.count) copias en \(work)")

/// Clase y no struct: la muta el handler de eventos, que corre en otra cola.
/// Con lock propio para no depender de quién la llame.
final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var _sawText = false
    private var _sawThinking = false
    private var _sawTool = false
    private var _sawDialog = false

    var sawText: Bool { lock.lock(); defer { lock.unlock() }; return _sawText }
    var sawThinking: Bool { lock.lock(); defer { lock.unlock() }; return _sawThinking }
    var sawTool: Bool { lock.lock(); defer { lock.unlock() }; return _sawTool }
    var sawDialog: Bool { lock.lock(); defer { lock.unlock() }; return _sawDialog }

    func bump(_ key: String) {
        lock.lock(); counts[key, default: 0] += 1; lock.unlock()
    }

    func mark(text: Bool = false, thinking: Bool = false, tool: Bool = false, dialog: Bool = false) {
        lock.lock()
        if text { _sawText = true }
        if thinking { _sawThinking = true }
        if tool { _sawTool = true }
        if dialog { _sawDialog = true }
        lock.unlock()
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return counts.sorted { $0.key < $1.key }.prefix(14)
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}

let observed = Observation()
var lastRetry: String?
var lastRetryFailure: String?

let config = SupervisorConfig(
    piExecutable: pi,
    defaultProfile: .lean,
    reapAfterSeconds: 5,
    maxLiveInstances: 2,
    reapOnMemoryPressure: true,
    tickInterval: 0.5
)
let supervisor = InstanceSupervisor(config: config, environment: environment)

supervisor.onInstanceStateChange = { _, state in
    line("   · estado → \(state.rawValue)")
}
supervisor.onReap = { key, outcome in
    let name = (key as NSString).lastPathComponent
    line("   · reciclado \(name): \(outcome.summary)")
}

// ── A. Lanzar y recuperar contexto ────────────────────────────────────────────

section("A. Lanzar sesión existente y recuperar su contexto")

let t0 = Date()
let first = try supervisor.acquire(.existing(path: copies[0]))
let boot = Date().timeIntervalSince(t0)
first.onEvent = { event in
    switch event {
    case .delta(let delta, _):
        observed.bump("delta")
        if delta.kind == .thinking { observed.mark(thinking: true) }
        if delta.kind == .text { observed.mark(text: true) }
    case .blockEnd(let block):
        observed.bump("blockEnd")
        if block.kind == .thinking { observed.mark(thinking: true) }
    case .messageStart: observed.bump("messageStart")
    case .messageEnd: observed.bump("messageEnd")
    case .agentStart: observed.bump("agentStart")
    case .agentSettled: observed.bump("agentSettled")
    case .turnStart: observed.bump("turnStart")
    case .turnEnd: observed.bump("turnEnd")
    case .thinkingLevelChanged: observed.bump("thinkingLevelChanged")
    case .sessionInfoChanged: observed.bump("sessionInfoChanged")
    case .retryStarted(let attempt, let maxAttempts, _):
        observed.bump("retryStarted")
        lastRetry = "intento \(attempt)/\(maxAttempts)"
    case .retryFinished(let success, let finalError):
        observed.bump("retryFinished")
        if !success { lastRetryFailure = finalError }
    case .extensionError: observed.bump("extensionError")
    case .compactionStart: observed.bump("compactionStart")
    case .compactionEnd: observed.bump("compactionEnd")
    case .toolExecutionStart:
        observed.bump("toolExecutionStart")
        observed.mark(tool: true)
    case .toolExecutionUpdate: observed.bump("toolExecutionUpdate")
    case .toolExecutionEnd: observed.bump("toolExecutionEnd")
    case .uiDialog:
        observed.bump("uiDialog")
        observed.mark(dialog: true)
    case .uiNotice: observed.bump("uiNotice")
    case .other(let type): observed.bump("other:\(type)")
    default: observed.bump(String(describing: event).prefix(28).description)
    }
}

check("handshake completo y estado idle", first.state == .idle, "\(String(format: "%.2f", boot))s")
check("contexto recuperado", first.messageCount > 0, "\(first.messageCount) mensajes")
let initialMessages = first.messageCount
line("   modelo: \(first.modelID ?? "?") · thinking: \(first.thinkingLevel ?? "?")")

let m0 = first.footprintBytes
let r0 = first.residentBytes
line("   memoria propia: \(ProcessMetrics.megabytes(m0)) · residente: \(ProcessMetrics.megabytes(r0))")
check("métricas de proceso disponibles", m0 != nil && r0 != nil)
check("la memoria propia es menor que la residente (páginas compartidas)",
      (m0 ?? 0) > 0 && (r0 ?? 0) > (m0 ?? 0),
      "propia \(ProcessMetrics.megabytes(m0)) < residente \(ProcessMetrics.megabytes(r0))")

supervisor.start()

// ── B. Estados durante una corrida con herramienta ───────────────────────────

section("B. Máquina de estados durante una corrida real con herramienta")

let prompt = "Usá la herramienta bash para ejecutar `sleep 6`, y cuando termine respondé exactamente: listo"
try first.sendPrompt(prompt)
line("   prompt enviado")

let sawWorking = poll(first, until: { $0 == .working }, timeout: 20)
check("pasa a working", sawWorking, "estado \(first.state.rawValue)")

// ── C. Nunca reciclar algo ocupado ───────────────────────────────────────────

section("C. NUNCA reciclar una instancia ocupada (regla de oro 3)")

let duringRun = supervisor.reapIdle(now: Date(), threshold: 0)
check("reciclado agresivo no toca una instancia trabajando",
      duringRun.isEmpty && first.isRunning,
      "recicladas: \(duringRun.count) · sigue viva: \(first.isRunning) · reciclable: \(first.isReapable)")

let capacityDuringRun = supervisor.enforceCapacity()
check("el tope de capacidad tampoco la toca mientras trabaja",
      capacityDuringRun.isEmpty && first.isRunning,
      "recicladas por capacidad: \(capacityDuringRun.count)")

// ── Esperar el fin real del run ──────────────────────────────────────────────

let settled = poll(first, until: { $0 == .idle }, timeout: 90)
check("termina en idle con agent_settled", settled, "estado \(first.state.rawValue)")

section("B (cont.) Qué llegó por el stream")
line("   eventos: \(observed.summary)")
line("   stopReason: \(first.lastStopReason ?? "?") · última corrida con error: \(first.lastRunErrored ? "SÍ" : "no")")
if let error = first.lastError { line("   último error reportado: \(error)") }
if let retry = lastRetry { line("   último reintento: \(retry)") }
if let failure = lastRetryFailure { line("   error final tras reintentos: \(failure)") }

let hadOutput = observed.count("delta") > 0
// Invariante duro: una corrida **nunca** termina en silencio. O hay salida, o hay error
// reportado. Esto es lo que descubrió Fase 1: el proveedor agotó reintentos y el estado
// igual caía en `idle` sin que nadie se enterara.
check("el run informa su resultado: salida o error, nunca silencio",
      hadOutput || first.lastError != nil,
      hadOutput ? "hubo deltas" : "sin deltas, con error reportado")
check("si hubo salida, se vio texto", !hadOutput || observed.sawText)
check("si hubo salida, se vio la herramienta",
      !hadOutput || observed.sawTool,
      "toolExecutionStart×\(observed.count("toolExecutionStart"))")
check("si hubo salida, se reportaron tokens", !hadOutput || first.usage.total > 0, first.usage.summary)
check("se vio el cierre real del run", observed.count("agentSettled") > 0,
      "agentSettled×\(observed.count("agentSettled")) · agentEnd no alcanza como señal")
check("los reintentos se decodifican y se registran",
      observed.count("retryStarted") + observed.count("retryFinished") > 0 || !first.lastRunErrored,
      "retryStarted×\(observed.count("retryStarted")) retryFinished×\(observed.count("retryFinished"))")
if observed.sawThinking {
    line("   pensamiento detectado: SÍ (\(first.liveThinking.count) caracteres)")
} else {
    line("   pensamiento detectado: no en esta corrida (depende del proveedor, no del nivel)")
}

// ── D. Reciclado por inactividad ─────────────────────────────────────────────

section("D. Reciclado por inactividad y liberación de memoria")

let beforeReap = supervisor.totalMemory()
line("   idle actual: \(String(format: "%.1f", first.idleSeconds))s · umbral \(Int(config.reapAfterSeconds))s")
line("   memoria total antes: propia \(ProcessMetrics.megabytes(beforeReap.footprint)) · residente \(ProcessMetrics.megabytes(beforeReap.resident))")

let waitDeadline = Date().addingTimeInterval(config.reapAfterSeconds + 6)
while Date() < waitDeadline && first.state != .cold { usleep(200_000) }
check("el reaper la recicló sola", first.state == .cold, "estado \(first.state.rawValue)")
check("el proceso ya no corre", !first.isRunning)
check("el pool quedó vacío", supervisor.allInstances().isEmpty,
      "\(supervisor.allInstances().count) instancias")

let afterReap = supervisor.totalMemory()
line("   memoria total después: propia \(ProcessMetrics.megabytes(afterReap.footprint)) · residente \(ProcessMetrics.megabytes(afterReap.resident))")
check("se liberó memoria", afterReap.footprint < beforeReap.footprint,
      "propia \(ProcessMetrics.megabytes(beforeReap.footprint)) → \(ProcessMetrics.megabytes(afterReap.footprint))")

let timeoutAudit = supervisor.auditLog.contains { $0.outcome.reason == .idleTimeout }
check("quedó registro auditable del reciclado", timeoutAudit,
      supervisor.auditLog.map { $0.outcome.reason.rawValue }.joined(separator: ", "))

// ── E. Despertar sin perder la conversación ──────────────────────────────────

section("E. Despertar después del reciclado, sin perder la conversación")

let messagesBefore = initialMessages
let liveBefore = first.liveMessageCount
let t1 = Date()
let woken = try supervisor.acquire(.existing(path: copies[0]))
let wakeTime = Date().timeIntervalSince(t1)
check("despertó en menos de 5 s", wakeTime < 5, "\(String(format: "%.2f", wakeTime))s")
check("es una instancia nueva (el proceso anterior murió)", woken !== first)
check("el contexto sobrevivió al reciclado",
      woken.messageCount >= messagesBefore,
      "persistidos \(messagesBefore) → \(woken.messageCount) (en vivo antes de reciclar: \(liveBefore))")
check("estado idle tras despertar", woken.state == .idle)
line("   memoria al despertar: propia \(ProcessMetrics.megabytes(woken.footprintBytes)) · residente \(ProcessMetrics.megabytes(woken.residentBytes))")

// ── F. Tope de instancias vivas ──────────────────────────────────────────────

section("F. Tope de instancias vivas con reciclado LRU")

for index in 1..<3 {
    try supervisor.acquire(.existing(path: copies[index]))
}
_ = supervisor.enforceCapacity()
let pool = supervisor.allInstances()
check("el pool no supera el tope de \(config.maxLiveInstances)", pool.count <= config.maxLiveInstances,
      "\(pool.count) vivas")
let capacityAudit = supervisor.auditLog.contains { $0.outcome.reason == .capacity }
check("hubo reciclado por capacidad", capacityAudit)

// ── G. Foto final ────────────────────────────────────────────────────────────

section("G. Panel de agentes (lo que verá la UI)")

_ = supervisor.enforceCapacity()
let phantom = supervisor.snapshot().filter { $0.state == .cold && $0.pid > 0 && !$0.reapable }
check("no quedan filas fantasma en el pool", phantom.isEmpty,
      "\(phantom.count) entradas en cold · \(supervisor.snapshot().count) filas")

for summary in supervisor.snapshot() {
    line("   " + summary.line)
}
let total = supervisor.totalMemory()
line("   TOTAL: propia \(ProcessMetrics.megabytes(total.footprint)) · residente \(ProcessMetrics.megabytes(total.resident))")

section("Cierre")
supervisor.shutdownAll()
let survivors = supervisor.allInstances().filter { $0.isRunning }
check("todo se apagó ordenadamente", survivors.isEmpty, "\(survivors.count) procesos vivos")
try? FileManager.default.removeItem(atPath: work)

line("")
line("\(checks - failures)/\(checks) verificaciones pasaron")
exit(failures == 0 ? 0 : 1)
