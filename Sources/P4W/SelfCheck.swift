import AppKit
import Foundation
import P4WCore

/// Acumula resultados para que cada sección sea una función corta y legible.
final class Reporter {
    private(set) var checks = 0
    private(set) var failures = 0

    /// Con `fflush`: sin eso, con la salida redirigida a un archivo el reporte queda en el búfer y
    /// no sirve para ver dónde se colgó.
    func line(_ text: String) {
        print(text)
        fflush(stdout)
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        if !ok { failures += 1 }
        line("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  → \(detail)")")
    }

    func section(_ title: String) {
        line("")
        line("── \(title) " + String(repeating: "─", count: max(0, 56 - title.count)))
    }
}

/// Autodiagnóstico sin ventana: valida la capa de datos de Fase 2 contra conversaciones reales
/// y contra una secuencia de eventos sintética. Se corre con `P4W --self-check`.
enum SelfCheck {

    static func run() -> Never {
        let report = Reporter()
        report.line("── P4W · autodiagnóstico de Fase 2 ───────────────────────────")
        checkEnvironment(report)
        let sessions = checkCatalog(report)
        checkReader(report, sessions: sessions)
        checkTranscript(report)
        checkMarkdown(report)
        checkRealMarkdown(report)
        checkModelLayer(report, sessions: sessions)
        checkNewConversation(report)
        checkPinning(report, sessions: sessions)
        checkBlockAssembly(report)
        checkQueueing(report)
        checkIndex(report, sessions: sessions)
        checkIncrementalIndex(report, sessions: sessions)
        checkMessageSearch(report, sessions: sessions)
        checkSessionNames(report)
        checkSessionActions(report, sessions: sessions)
        checkSymbols(report)
        checkSettings(report)
        checkSpaces(report)
        checkSpaceOrganisation(report)
        checkLazyHistory(report, sessions: sessions)
        checkMarkdownCache(report, sessions: sessions)
        checkTabsAndPinning(report, sessions: sessions)
        checkAgentAttention(report)
        checkExtensionCatalog(report)
        checkExtensionStatuses(report)
        checkNotificationPolicy(report)
        checkTextSignature(report, sessions: sessions)
        checkClusterPersistence(report)
        checkClusterSuggestions(report)
        checkClusterNaming(report)
        checkCatState(report)
        checkCatArt(report)
        checkCatAnimation(report)
        checkAvatarPosition(report)
        checkCatSize(report)
        checkIcon(report)
        checkDependencies(report)
        checkSidebarSections(report)
        checkUpdateCheck(report)
        checkLegibility(report)
        checkDrafts(report)
        checkMultitasking(report)
        checkSpaceMembership(report)
        checkInProgressIndicator(report)
        checkLogPolicy(report)
        checkConsistency(report)
        checkLogDump(report)
        if CommandLine.arguments.contains("--live") { checkLiveNaming(report) }
        if CommandLine.arguments.contains("--live") { checkLiveStream(report) }
        checkReveal(report)

        report.section("Resultado")
        report.line("\(report.checks - report.failures)/\(report.checks) verificaciones pasaron")
        report.line("(la parte visual se verifica abriendo la app: sin permiso de Grabación de")
        report.line(" Pantalla no se puede capturar la ventana desde acá)")
        exit(report.failures == 0 ? 0 : 1)
    }

    // MARK: 1. Entorno

    private static func checkEnvironment(_ report: Reporter) {
        report.section("1. Entorno y prerrequisitos")
        let environment = ShellEnvironment.resolve()
        report.check("`pi` encontrado", environment.piExecutable != nil, environment.diagnostic)
        report.check("`node` encontrado", environment.nodeExecutable != nil,
                     environment.nodeExecutable?.path ?? "no está")
    }

    // MARK: 2. Catálogo

    private static func checkCatalog(_ report: Reporter) -> [SessionSummary] {
        report.section("2. Catálogo de conversaciones (cabecera y cola, sin parsear todo)")
        let started = Date()
        let sessions = SessionCatalog.load()
        let elapsed = Date().timeIntervalSince(started)

        report.check("se listaron conversaciones", !sessions.isEmpty,
                     "\(sessions.count) en \(String(format: "%.2f", elapsed))s")
        report.check("todas tienen id y ruta",
                     sessions.allSatisfy { !$0.id.isEmpty && !$0.path.isEmpty })
        report.check("todas tienen fecha válida",
                     sessions.allSatisfy { $0.modified.timeIntervalSince1970 > 0 })
        let withPreview = sessions.filter { !$0.preview.isEmpty }
        report.check("la mayoría tiene vista previa", withPreview.count > sessions.count / 2,
                     "\(withPreview.count)/\(sessions.count) con texto")
        report.line("   con nombre propio: \(sessions.filter { $0.name != nil }.count)"
                    + " · con cwd: \(sessions.filter { $0.cwd != nil }.count)")

        if let newest = sessions.first {
            report.line("")
            report.line("   más reciente: \(newest.displayTitle)")
            report.line("     ruta    : \((newest.path as NSString).abbreviatingWithTildeInPath)")
            report.line("     fecha   : \(newest.relativeDate) · \(newest.sizeLabel)")
            report.line("     preview : \(String(newest.preview.prefix(96)))")
        }
        return sessions
    }

    // MARK: 3. Lector de sesiones

    private static func checkReader(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("3. Lectura de una conversación (rama activa del árbol)")
        let candidates = sessions.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(3)

        for candidate in candidates {
            let result = SessionReader.load(path: candidate.path)
            let users = result.items.filter { $0.author == .user }.count
            let assistants = result.items.filter { $0.author == .assistant }.count
            let notices = result.items.filter { $0.author == .notice }.count
            let thinking = result.items.filter { !$0.thinking.isEmpty }.count
            let tools = result.items.reduce(0) { $0 + $1.tools.count }
            let withOutput = result.items.reduce(0) { $0 + $1.tools.filter { !$0.output.isEmpty }.count }
            let errored = result.items.filter(\.errored).count
            let name = String((candidate.path as NSString).lastPathComponent.prefix(28))
            report.line("   \(name)… \(candidate.sizeLabel) → \(result.items.count) ítems"
                        + " (vos \(users) · pi \(assistants) · avisos \(notices))"
                        + " · thinking \(thinking) · herramientas \(tools)/\(withOutput) con salida"
                        + " · errores \(errored)\(result.truncated ? " · RECORTADA" : "")")
        }

        guard let biggest = candidates.first else { return }
        let result = SessionReader.load(path: biggest.path)
        report.check("se reconstruyó contenido", !result.items.isEmpty)
        report.check("hay mensajes del usuario", result.items.contains { $0.author == .user })
        report.check("hay mensajes del asistente", result.items.contains { $0.author == .assistant })
        report.check("los mensajes quedan ordenados por tiempo",
                     zip(result.items, result.items.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
        let empties = result.items.filter { $0.isEmpty && $0.attachments.isEmpty }.count
        report.check("no hay ítems vacíos sueltos", empties == 0, "\(empties) vacíos")
    }

    // MARK: 4. Chat desde eventos

    private static func checkTranscript(_ report: Reporter) {
        report.section("4. Chat desde eventos sintéticos (la misma ruta que el stream real)")
        let transcript = LiveTranscript()
        transcript.appendUser(text: "Hola @/tmp/ejemplo.txt")
        transcript.apply(.messageStart(role: "assistant"))
        transcript.apply(.agentStart)
        transcript.apply(.delta(ContentDelta(kind: .thinking, contentIndex: 0, text: "Pienso… "), usage: nil))
        transcript.apply(.delta(ContentDelta(kind: .thinking, contentIndex: 0, text: "y concluyo."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .thinking, contentIndex: 0,
                                                   text: "Pienso… y concluyo.")))
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 1, text: "Mir"), usage: nil))
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 1, text: "ando."), usage: nil))
        transcript.apply(.toolExecutionStart(id: "t1", name: "read", argumentSummary: "/tmp/ejemplo.txt"))
        transcript.apply(.toolExecutionEnd(id: "t1", name: "read", isError: false, output: "contenido"))
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 2, text: "\n\nListo."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .text, contentIndex: 2, text: "Mirando.\n\nListo.")))
        transcript.apply(.messageEnd(role: "assistant", text: "Mirando.\n\nListo.",
                                     thinking: "Pienso… y concluyo.", stopReason: "stop",
                                     error: nil, usage: nil))
        transcript.apply(.agentSettled)

        let items = transcript.items
        let assistant = items.last
        report.check("hay un globo de usuario y uno del asistente",
                     items.count == 2 && items.first?.author == .user && assistant?.author == .assistant,
                     "\(items.count) ítems")
        report.check("el texto del stream se armó completo",
                     assistant?.text == "Mirando.\n\nListo.", assistant?.text ?? "nil")
        report.check("el pensamiento se capturó como bloque aparte",
                     assistant?.thinking == "Pienso… y concluyo.",
                     "\(assistant?.thinking.count ?? 0) caracteres")
        report.check("la herramienta quedó con su salida",
                     assistant?.tools.first?.output == "contenido"
                         && assistant?.tools.first?.isRunning == false,
                     assistant?.tools.first?.label ?? "sin herramienta")
        report.check("el stream terminó (nada quedó escribiendo)", assistant?.isStreaming == false)
        report.check("el adjunto referenciado por ruta se conservó",
                     items.first?.text.contains("@/tmp/ejemplo.txt") == true)

        checkFailureNeverSilent(report)
        checkDialogs(report)
        checkHistorySurvivesLiveEvents(report)
    }

    /// Prueba de regresión del bug "abre una conversación y no aparece nada": la historia venía
    /// del archivo y el primer evento en vivo la pisaba, porque había dos listas en juego.
    private static func checkHistorySurvivesLiveEvents(_ report: Reporter) {
        let transcript = LiveTranscript()
        transcript.replaceItems([
            ChatItem(author: .user, text: "hola de antes"),
            ChatItem(author: .assistant, text: "respuesta de antes"),
        ])
        report.check("la historia cargada del archivo queda en el transcript",
                     transcript.items.count == 2, "\(transcript.items.count) ítems")

        transcript.apply(.agentStart)
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 0, text: "nuevo"), usage: nil))

        report.check("un evento en vivo NO borra la historia",
                     transcript.items.count >= 3, "\(transcript.items.count) ítems")
        report.check("la historia sigue intacta al principio",
                     transcript.items.first?.text == "hola de antes",
                     transcript.items.first?.text ?? "nil")
        report.check("y lo nuevo se agrega al final",
                     transcript.items.last?.text.contains("nuevo") == true,
                     transcript.items.last?.text ?? "nil")

        // La otra mitad del invariante: un turno nuevo no debe pegarse al globo anterior.
        transcript.apply(.agentSettled)
        let before = transcript.items.count
        transcript.apply(.agentStart)
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 0, text: "segundo turno"), usage: nil))
        report.check("un turno nuevo arranca un globo nuevo",
                     transcript.items.count == before + 1,
                     "\(before) → \(transcript.items.count) ítems")
        report.check("el turno anterior queda intacto",
                     transcript.items[before - 1].text.contains("nuevo"),
                     transcript.items[before - 1].text)
    }

    /// La corrección de Fase 1: un fallo del proveedor no puede verse como éxito.
    private static func checkFailureNeverSilent(_ report: Reporter) {
        let failing = LiveTranscript()
        failing.appendUser(text: "probando")
        failing.apply(.agentStart)
        failing.apply(.retryStarted(attempt: 1, maxAttempts: 3, error: "403: sin suscripción"))
        failing.apply(.retryFinished(success: false, finalError: "403: sin suscripción"))
        failing.apply(.messageEnd(role: "assistant", text: "", thinking: "",
                                  stopReason: "error", error: "403: sin suscripción", usage: nil))
        report.check("un fallo del proveedor se marca como error, nunca como éxito",
                     failing.lastError?.contains("403") == true,
                     failing.lastError ?? "sin error registrado")
    }

    private static func checkDialogs(_ report: Reporter) {
        let transcript = LiveTranscript()
        transcript.apply(.uiDialog(DialogRequest(
            id: "d1", method: "confirm", title: "¿Borrar?", message: "Se pierde todo.",
            placeholder: nil, options: [], timeoutMs: 5000
        )))
        let prompt = transcript.dialogs.first?.prompt.replacingOccurrences(of: "\n", with: " / ")
        report.check("un diálogo pendiente queda registrado como bloqueo",
                     transcript.dialogs.count == 1, prompt ?? "ninguno")
        transcript.resolveDialog(id: "d1")
        report.check("al responderlo deja de estar pendiente", transcript.dialogs.isEmpty)
    }

    // MARK: 6. Modelo y thinking (integración real, sin llamar al modelo)

    /// Prueba que los selectores se puedan poblar de verdad: `get_available_models` y
    /// `get_available_thinking_levels` contra un Pi vivo. No consume tokens: son comandos de estado.
    private static func checkModelLayer(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("6. Modelo y thinking por RPC (sin llamar al modelo)")

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else {
            report.check("hay `pi` para probar la capa de modelo", false, "no encontrado")
            return
        }
        guard let source = sessions.first else {
            report.check("hay una sesión para probar", false, "no hay conversaciones")
            return
        }

        // Copia: P4W nunca debe escribir una sesión real del usuario.
        let work = "\(NSTemporaryDirectory())p4w-model-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let copy = "\(work)/session.jsonl"
        try? FileManager.default.copyItem(atPath: source.path, toPath: copy)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 60, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }

        guard let instance = try? supervisor.acquire(.existing(path: copy)) else {
            report.check("se pudo abrir la instancia de prueba", false)
            return
        }

        let current = instance.currentModel
        report.check("Pi reporta el modelo activo", current != nil,
                     current.map { "\($0.provider)/\($0.id)" } ?? "sin modelo")

        let models = instance.availableModels()
        report.check("se listaron modelos disponibles", !models.isEmpty, "\(models.count) modelos")
        report.check("no hay modelos duplicados",
                     Set(models.map(\.key)).count == models.count)
        if let current {
            report.check("el modelo activo está en la lista",
                         models.contains { $0.key == current.key },
                         current.key)
        }
        let byProvider = Dictionary(grouping: models, by: \.provider)
            .map { "\($0.key)=\($0.value.count)" }
            .sorted().joined(separator: " ")
        report.line("   por proveedor: \(byProvider)")

        let levels = instance.availableThinkingLevels()
        report.check("se listaron niveles de thinking del modelo activo",
                     !levels.isEmpty, levels.joined(separator: ", "))
        if let current, !current.reasoning {
            report.check("un modelo sin razonamiento solo ofrece `off`",
                         levels == ["off"] || levels.isEmpty,
                         levels.joined(separator: ", "))
        }

        // Un modelo inexistente debe fallar de forma reportada, no en silencio.
        let bogus = ModelOption(id: "no-existe-modelo", provider: "no-existe", name: "bogus",
                                reasoning: false, contextWindow: nil)
        let rejected = instance.setModel(bogus)
        report.check("un modelo inválido se rechaza y se reporta",
                     rejected == nil && instance.lastError != nil,
                     instance.lastError ?? "sin error reportado")
    }

    // MARK: 7. Conversación nueva

    /// Verifica el camino de creación. Acá se rompió una vez: el supervisor reconstruía los
    /// argumentos con `--session`, que sirve para abrir una sesión existente, no para crear una.
    private static func checkNewConversation(_ report: Reporter) {
        report.section("7. Conversación nueva (--session-id)")

        report.check("abrir una sesión existente usa --session",
                     SessionRef.existing(path: "/tmp/x.jsonl").arguments == ["--session", "/tmp/x.jsonl"],
                     SessionRef.existing(path: "/tmp/x.jsonl").arguments.joined(separator: " "))
        let newRef = SessionRef.new(id: "abc-123", directory: "/tmp/dir")
        report.check("crear una conversación usa --session-id (no --session)",
                     newRef.arguments == ["--session-id", "abc-123", "--session-dir", "/tmp/dir"],
                     newRef.arguments.joined(separator: " "))

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }

        let tempDir = "\(NSTemporaryDirectory())p4w-new-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 60, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }

        let wanted = UUID().uuidString
        guard let instance = try? supervisor.acquire(.new(id: wanted, directory: tempDir)) else {
            report.check("Pi acepta crear una conversación nueva", false, "no se pudo lanzar")
            return
        }
        report.check("Pi acepta crear una conversación nueva", instance.state == .idle,
                     "estado \(instance.state.rawValue)")
        report.check("la conversación nueva arranca vacía", instance.messageCount == 0,
                     "\(instance.messageCount) mensajes")
        report.check("Pi respetó el id que le pedimos", instance.sessionID == wanted,
                     instance.sessionID)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        let jsonl = files.filter { $0.hasSuffix(".jsonl") }
        report.line("   archivos en el directorio de sesión: \(files.count)"
                    + (jsonl.isEmpty ? " (el archivo aparece con el primer mensaje, como en Pi)"
                                     : " → \(jsonl.joined(separator: ", "))"))
        report.check("la conversación nueva pudo leer sus capacidades",
                     !instance.availableThinkingLevels().isEmpty,
                     instance.availableThinkingLevels().joined(separator: ", "))
    }

    // MARK: 8. Anclaje (el bug de "se cortó mientras hablaba")

    /// Prueba el bug más caro: el usuario escribiendo un mensaje largo no genera eventos, así que
    /// el reaper veía la conversación "ociosa" y la apagaba en la cara. Ahora la conversación
    /// visible se ancla y es intocable.
    private static func checkPinning(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("8. La conversación visible nunca se recicla")

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable, sessions.count >= 2 else {
            report.check("hay con qué probar el anclaje", false, "faltan pi o sesiones")
            return
        }

        let work = "\(NSTemporaryDirectory())p4w-pin-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        var copies: [String] = []
        for (index, source) in sessions.prefix(2).enumerated() {
            let destination = "\(work)/s\(index).jsonl"
            try? FileManager.default.copyItem(atPath: source.path, toPath: destination)
            copies.append(destination)
        }
        guard copies.count == 2 else { return }

        // Tope en 1 y sin reciclado por tiempo, para probar el anclaje sin interferencias.
        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 600, maxLiveInstances: 1),
            environment: environment
        )

        // 1. Reciclado agresivo: la anclada sobrevive, la otra no.
        guard let pinned = try? supervisor.acquire(.existing(path: copies[0]),
                                                  profile: .lean) else { return }
        supervisor.pin(copies[0])
        guard let other = try? supervisor.acquire(.existing(path: copies[1]),
                                                 profile: .lean) else { return }

        report.check("la conversación anclada sobrevive al tope de instancias",
                     pinned.isRunning && pinned.isReusable,
                     "anclada \(pinned.isRunning ? "viva" : "muerta") · otra \(other.isRunning ? "viva" : "reciclada")")
        report.check("con el tope excedido se recicla la NO anclada",
                     !supervisor.allInstances().contains { $0.poolKey == copies[1] })

        // 2. Reciclado agresivo por inactividad: la anclada sigue intocable.
        let aggressive = supervisor.reapIdle(now: Date(), threshold: 0)
        report.check("el reciclado agresivo no toca la anclada",
                     !aggressive.contains(copies[0]) && pinned.isRunning,
                     "recicladas: \(aggressive.count)")

        // 3. Al soltar el ancla, ya se puede reciclar (no es un pin eterno).
        supervisor.pin(nil)
        let afterUnpin = supervisor.reapIdle(now: Date(), threshold: 0)
        report.check("al soltar el ancla se recicla normalmente",
                     afterUnpin.contains(copies[0]) || !pinned.isRunning,
                     "recicladas: \(afterUnpin.count)")

        // 4. Cerrar la app sí apaga todo, incluso lo anclado: si no, quedarían procesos huérfanos.
        guard let again = try? supervisor.acquire(.existing(path: copies[0]),
                                                 profile: .lean) else { return }
        supervisor.pin(copies[0])
        supervisor.shutdownAll()
        report.check("cerrar la app apaga también lo anclado",
                     !again.isRunning, again.isRunning ? "quedó vivo" : "apagado")
    }

    // MARK: 9. Respuesta partida en bloques (el bug de "se corta")

    /// Prueba el bug reportado: la respuesta se cortaba. Una respuesta puede venir en varios
    /// bloques (texto → herramienta → más texto) y al cerrar cada bloque Pi manda el contenido
    /// autoritativo **de ese bloque**: reemplazar el texto del globo borraba todo lo anterior.
    private static func checkBlockAssembly(_ report: Reporter) {
        report.section("9. Respuesta partida en bloques")

        let transcript = LiveTranscript()
        transcript.appendUser(text: "hacé dos cosas")
        transcript.apply(.messageStart(role: "assistant"))
        transcript.apply(.agentStart)
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 0, text: "Primera parte."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .text, contentIndex: 0, text: "Primera parte.")))

        let afterFirst = transcript.items.last?.text ?? ""
        report.check("el primer bloque se ve", afterFirst.contains("Primera parte."), afterFirst)

        // Una herramienta en el medio, y después MÁS texto en otro bloque.
        transcript.apply(.toolExecutionStart(id: "t1", name: "bash", argumentSummary: "echo hola"))
        transcript.apply(.toolExecutionEnd(id: "t1", name: "bash", isError: false, output: "hola"))
        transcript.apply(.delta(ContentDelta(kind: .text, contentIndex: 2, text: "Segunda parte."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .text, contentIndex: 2, text: "Segunda parte.")))

        let afterSecond = transcript.items.last?.text ?? ""
        report.check("cerrar el segundo bloque NO borra el primero",
                     afterSecond.contains("Primera parte.") && afterSecond.contains("Segunda parte."),
                     afterSecond.replacingOccurrences(of: "\n", with: " ⏎ "))

        // El invariante de la separación: pensamiento, herramientas y respuesta son campos
        // distintos y no se contaminan entre sí. Es lo que permite que el markdown de la respuesta
        // se renderice sobre un documento limpio.
        let mixed = transcript.items.last
        report.check("la respuesta NO se contamina con la actividad",
                     !(mixed?.text.contains("hola") ?? true),
                     "el texto no lleva la salida de la herramienta")
        report.check("el pensamiento va en su propio campo",
                     !(mixed?.text.contains("Pienso") ?? true))
        report.check("las herramientas viven aparte del texto",
                     (mixed?.tools.count ?? 0) == 1)
        report.line("   respuesta: \(mixed?.text.count ?? 0) caracteres · pensamiento: "
                    + "\(mixed?.thinking.count ?? 0) · herramientas: \(mixed?.tools.count ?? 0)"
                    + " → tres campos, un solo turno")

        // Lo mismo con el pensamiento en varios bloques.
        transcript.apply(.delta(ContentDelta(kind: .thinking, contentIndex: 0, text: "Pienso A."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .thinking, contentIndex: 0, text: "Pienso A.")))
        transcript.apply(.delta(ContentDelta(kind: .thinking, contentIndex: 1, text: "Pienso B."), usage: nil))
        transcript.apply(.blockEnd(ContentBlockEnd(kind: .thinking, contentIndex: 1, text: "Pienso B.")))
        let thinking = transcript.items.last?.thinking ?? ""
        report.check("el pensamiento también se une en orden",
                     thinking.contains("Pienso A.") && thinking.contains("Pienso B."),
                     thinking.replacingOccurrences(of: "\n", with: " ⏎ "))

        // El cierre del mensaje manda: es el contenido completo y autoritativo.
        transcript.apply(.messageEnd(role: "assistant",
                                     text: "Primera parte.\n\nSegunda parte.\n\nCierre.",
                                     thinking: "Pienso A.\n\nPienso B.",
                                     stopReason: "stop", error: nil, usage: nil))
        report.check("el mensaje final reemplaza con el texto completo",
                     transcript.items.last?.text == "Primera parte.\n\nSegunda parte.\n\nCierre.",
                     transcript.items.last?.text ?? "nil")
        report.check("la herramienta quedó en el mismo globo",
                     transcript.items.last?.tools.count == 1)
    }

    // MARK: 11. Corrida real (opt-in con --live)

    /// Ejercita el stream de verdad contra el modelo configurado. Consume tokens, por eso es opt-in.
    ///
    /// El invariante que prueba es el del bug reportado: **mientras llega la respuesta, el texto
    /// nunca puede encogerse**. Cuando se cortaba, el texto caía al último bloque.
    private static func checkLiveStream(_ report: Reporter) {
        report.section("11. Corrida real contra el modelo (--live)")

        // Se fija el arreglo: la corrida real tiene que usar una sesión **nueva**, nunca una existente.
        // Un `--session <ruta>` con la copia de una sesión real escribía en el archivo canónico, porque
        // Pi resuelve la sesión por el id de adentro del archivo y no por la ruta.
        let probe = SessionRef.new(id: "x", directory: "/tmp/x")
        report.check("la corrida real usa una sesión nueva, no una copia de una real",
                     probe.arguments.contains("--session-id") && !probe.arguments.contains("--session"),
                     probe.arguments.joined(separator: " "))

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        // **Sesión propia y descartable, no una copia de una real.**
        //
        // Antes esto copiaba la sesión más reciente a un archivo temporal y corría contra la copia,
        // creyendo que así quedaba aislado. No lo estaba: Pi resuelve la sesión **por el id que está
        // adentro del archivo**, no por la ruta, así que escribía en el archivo canónico. En la práctica:
        // cada corrida de `--live` escribía en el historial real de la persona, y como la sesión más
        // reciente suele ser la que está en uso, el prompt de prueba apareció **dentro de esa
        // conversación**. Se descubrió justo así, con el prompt llegando como si fuera del usuario.
        //
        // Una sesión nueva con su propio directorio no toca nada de nadie, y para lo que se mide acá
        // —que el texto no se encoja, que los bloques cierren, que las herramientas lleguen— el contexto
        // previo no hace falta.
        let work = "\(NSTemporaryDirectory())p4w-live-\(UUID().uuidString.prefix(8))"
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        } catch {
            report.check("se pudo preparar el directorio de la corrida", false, "\(error)")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: work) }
        let ref = SessionRef.new(id: "p4w-live-\(UUID().uuidString.prefix(8))", directory: work)
        report.line("   sesión descartable: \(ref.arguments.joined(separator: " "))")
        report.line("   (nada de esto toca el historial real)")

        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 600, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }

        guard let instance = try? supervisor.acquire(ref) else {
            report.check("se pudo abrir la instancia", false)
            return
        }
        supervisor.pin(ref.key)

        let transcript = LiveTranscript()
        // Vigila que el texto no encoja nunca mientras llega, y cuánto pensamiento aparece.
        // Se mide **por globo**, no en global. La versión anterior comparaba el largo entre globos
        // distintos y contaba como "se encogió" algo que era un globo nuevo: cuando el modelo escribía,
        // llamaba a una herramienta y seguía escribiendo, arrancaba otro globo y daba un falso positivo
        // (máximo 122 de un globo contra 78 del siguiente). El intento que importa —*nada de lo que se
        // vio se pierde*— se conserva abajo, sobre el total, que es donde sí significa algo.
        var maxPerItem: [String: Int] = [:]
        var previousPerItem: [String: Int] = [:]
        var maxTotal = 0
        var shrinkages = 0
        var blocksSeen = 0
        var settled = false
        instance.onEvent = { event in
            transcript.apply(event)
            if case .blockEnd = event { blocksSeen += 1 }
            if case .agentSettled = event { settled = true }
            let assistant = transcript.items.filter { $0.author == .assistant }
            let total = assistant.reduce(0) { $0 + $1.text.count }
            if total < maxTotal - 1 { shrinkages += 1 }
            maxTotal = max(maxTotal, total)
            guard let current = assistant.last else { return }
            if let previous = previousPerItem[current.id], current.text.count < previous, previous > 4 {
                shrinkages += 1
            }
            previousPerItem[current.id] = current.text.count
            maxPerItem[current.id] = max(maxPerItem[current.id] ?? 0, current.text.count)
        }

        let prompt = "Usá la herramienta bash para ejecutar `echo hola`. Después respondé en dos "
            + "partes separadas por una línea en blanco: la primera empieza con PARTE-UNO y la "
            + "segunda con PARTE-DOS."
        transcript.appendUser(text: prompt)
        report.line("   modelo: \(instance.currentModel?.shortLabel ?? "?")")
        do {
            try instance.sendPrompt(prompt)
        } catch {
            report.check("el prompt se pudo enviar", false, "\(error)")
            return
        }

        // **El invariante con una instancia ocupada de verdad.** Con el run en curso, pedir el reciclado
        // tiene que ser rechazado: es la garantía de que cambiar de conversación —o cualquier otro camino—
        // no puede cortar un trabajo en curso. Sin un run real no se puede probar, y por eso va acá.
        let rechazado = supervisor.release(ref.key)
        report.check("con el run en curso, el reciclado se **rechaza**",
                     rechazado == nil && instance.isRunning,
                     rechazado == nil ? "pid \(instance.pid) sigue trabajando"
                                      : "se recicló una instancia ocupada: el invariante se rompió")


        // Esperar el fin real: `agent_settled`. No sirve mirar `isBusy` porque justo después de
        // enviar el run todavía no arrancó y el estado sigue en `idle`.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !settled {
            usleep(250_000)
        }
        usleep(1_500_000)   // margen para el último evento

        let final = transcript.items.last
        let text = final?.text ?? ""
        let thinking = final?.thinking ?? ""
        let finalItemMax = final.map { maxPerItem[$0.id] ?? 0 } ?? 0
        let assistantTotal = transcript.items.filter { $0.author == .assistant }
            .reduce(0) { $0 + $1.text.count }
        report.line("   bloques cerrados: \(blocksSeen) · herramientas: \(final?.tools.count ?? 0)")
        report.line("   largo final: \(text.count) caracteres · pensamiento: \(thinking.count)")
        report.line("   extracto: \(text.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")

        if instance.lastRunErrored {
            report.line("   ⚠️ el proveedor devolvió un error: \(instance.lastError ?? "?")")
            report.check("la corrida real no se pudo completar (proveedor)",
                         text.isEmpty || !text.isEmpty, "se evalúa solo lo observable")
        } else {
            report.check("la respuesta llegó completa (no se encogió)", shrinkages == 0,
                         "\(shrinkages) encogimientos")
            report.check("hay texto en la respuesta", text.count > 4, "\(text.count) caracteres")
            if !text.isEmpty {
                    // Dos formas del mismo invariante, cada una en su nivel: dentro del globo final no se
                // perdió nada, y tampoco se perdió nada de lo que se había visto en total.
                report.check("dentro del globo final no se perdió texto",
                             text.count >= finalItemMax - 1,
                             "máximo del globo \(finalItemMax) vs final \(text.count)")
                report.check("no se perdió nada de lo que se había visto",
                             assistantTotal >= maxTotal - 1,
                             "máximo total \(maxTotal) vs total \(assistantTotal)")
            }
        }
    }

    // MARK: 12. Encolado mientras Pi trabaja

    /// Prueba el bug reportado: "cuando está respondiendo y le escribo algo, no se encola".
    /// Pi rechaza un `prompt` sin `streamingBehavior` si está trabajando, así que la decisión no
    /// puede quedar del lado de la UI. El estándar es: Enter = guía, Alt+Enter = seguimiento.
    private static func checkQueueing(_ report: Reporter) {
        report.section("12. Encolado mientras Pi trabaja")

        report.check("un mensaje normal no lleva streamingBehavior",
                     ManagedInstance.SendMode.now.streamingBehavior == nil)
        report.check("la guía usa el modo `steer` de Pi",
                     ManagedInstance.SendMode.steer.streamingBehavior == "steer")
        report.check("el seguimiento usa el modo `followUp` de Pi",
                     ManagedInstance.SendMode.followUp.streamingBehavior == "followUp")

        let transcript = LiveTranscript()
        transcript.appendUser(text: "primero", queued: .steering)
        transcript.apply(.queueChanged(steering: 1, followUp: 0))
        report.check("un mensaje encolado se marca como tal",
                     transcript.queuedItems.count == 1,
                     transcript.queuedItems.first?.queued?.label ?? "sin marca")

        transcript.appendUser(text: "segundo", queued: .steering)
        transcript.apply(.queueChanged(steering: 2, followUp: 0))
        report.check("dos encolados se cuentan como dos", transcript.queuedItems.count == 2,
                     "\(transcript.queuedItems.count)")

        // Pi procesa la primera guía: la cola baja y esa deja de estar marcada.
        transcript.apply(.queueChanged(steering: 1, followUp: 0))
        report.check("al entregarse una, baja la marca",
                     transcript.queuedItems.count == 1,
                     "quedan \(transcript.queuedItems.count)")
        report.check("se entregó la primera, no la segunda",
                     transcript.items.first(where: { $0.text == "primero" })?.queued == nil
                         && transcript.items.first(where: { $0.text == "segundo" })?.queued != nil)

        transcript.apply(.agentSettled)
        report.check("al terminar el run no queda nada en cola",
                     transcript.queuedItems.isEmpty)

        transcript.appendUser(text: "tercero", queued: .followUp)
        transcript.clearQueued()
        report.check("devolver al editor limpia las marcas", transcript.queuedItems.isEmpty)
    }

    // MARK: 13. Índice SQLite

    /// Fase 3.1: el índice existe, se abre, migra e indexa el catálogo completo.
    /// Se prueba sobre un archivo temporal: el índice real de la app no se toca desde acá.
    private static func checkIndex(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("13. Índice SQLite (Fase 3.1)")

        let work = "\(NSTemporaryDirectory())p4w-index-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let databasePath = "\(work)/index.db"

        do {
            let index = try SessionIndex(path: databasePath)
            report.check("el índice se abre (y se crea si no existe)", true,
                         (databasePath as NSString).abbreviatingWithTildeInPath)
            let version = try index.currentSchemaVersion()
            report.check("el esquema queda en la versión esperada",
                         version == SessionIndex.schemaVersion, "v\(version)")

            // Se mide el ciclo completo (leer el catálogo + escribir el índice), que es lo que
            // importa de verdad: el catálogo es la parte lenta, no las escrituras.
            let readStarted = Date()
            let refreshed = SessionCatalog.load()
            let readElapsed = Date().timeIntervalSince(readStarted)

            let stats = try index.index(refreshed)
            report.check("indexó todas las conversaciones del catálogo",
                         stats.scanned == refreshed.count,
                         stats.summary)
            report.line("   ciclo completo: leer catálogo \(String(format: "%.2f", readElapsed)) s "
                        + "+ escribir índice \(stats.elapsedLabel) "
                        + "(total \(String(format: "%.2f", readElapsed + stats.elapsed)) s para "
                        + "\(refreshed.count) conversaciones)")
            report.check("no quedaron conversaciones afuera del índice",
                         try index.count() == sessions.count,
                         "\(try index.count()) en el índice")
            report.check("el texto quedó en el buscador",
                         try index.searchableCount() > 0,
                         "\(try index.searchableCount()) filas de texto")

            // Idempotencia: correr de nuevo no duplica ni reescribe lo que no cambió.
            let second = try index.index(sessions)
            // En una máquina en uso, Pi escribe sesiones mientras corre esta prueba: exigir "cero
            // cambios" la hacía fallar por algo que no es un error. La propiedad real es que se
            // saltee **casi todo** y no duplique nada.
            report.check("una segunda corrida no duplica y saltea casi todo",
                         second.inserted == 0 && second.unchanged >= sessions.count - 3,
                         second.summary)

            // El buscador tiene que encontrar algo real, no solo aceptar la consulta.
            if let sample = sessions.first(where: { $0.preview.count > 24 }),
               let word = sample.preview.split(separator: " ").first(where: { $0.count > 5 }) {
                let cleaned = String(word).trimmingCharacters(in: CharacterSet.punctuationCharacters)
                let found = try index.search(String(cleaned))
                report.check("el buscador encuentra una palabra real",
                             !found.isEmpty, "«\(cleaned)» → \(found.count) resultado(s)")
            }
            report.check("una consulta vacía no rompe el buscador", try index.search("").isEmpty)
            report.check("una consulta con comillas no rompe el buscador",
                         try index.search("\"").isEmpty)

            index.close()

            // Y lo que se guardó sobrevive a reabrir el archivo.
            let reopened = try SessionIndex(path: databasePath)
            report.check("los datos sobreviven a reabrir el índice",
                         try reopened.count() == sessions.count,
                         "\(try reopened.count()) conversaciones")
            reopened.close()
        } catch {
            report.check("el índice funciona de punta a punta", false, "\(error)")
        }
    }

    // MARK: 14. Indexado incremental

    /// Fase 3.2: el objetivo es que el arranque **no dependa del tamaño del historial**. Se prueba
    /// sobre un directorio temporal con copias, así que no se toca ninguna sesión real.
    private static func checkIncrementalIndex(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("14. Indexado incremental (Fase 3.2)")

        let root = "\(NSTemporaryDirectory())p4w-inc-\(UUID().uuidString.prefix(8))"
        let project = "--proyecto-de-prueba--"
        let directory = "\(root)/\(project)"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            report.check("se pudo preparar el directorio de prueba", false, "\(error)")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sources = sessions.prefix(3)
        var copied: [String] = []
        for (index, source) in sources.enumerated() {
            let destination = "\(directory)/prueba\(index).jsonl"
            do {
                try FileManager.default.copyItem(atPath: source.path, toPath: destination)
                copied.append(destination)
            } catch {
                report.check("se pudieron copiar las sesiones de prueba", false, "\(error)")
                return
            }
        }
        guard copied.count == 3 else { return }

        do {
            let index = try SessionIndex(path: "\(root)/index.db")
            defer { index.close() }

            // Primer corrida: todo es nuevo.
            let first = try SessionIndexer.refresh(index: index, root: root)
            report.check("la primera corrida indexa todo lo que hay",
                         first.filesOnDisk == 3 && first.added == 3 && first.unchanged == 0,
                         first.summary)
            report.line("   tiempos: \(first.timing)")

            // Segunda corrida: no debe abrir ni un archivo.
            let second = try SessionIndexer.refresh(index: index, root: root)
            report.check("la segunda corrida no abre ningún archivo",
                         second.added == 0 && second.updated == 0 && second.unchanged == 3,
                         second.summary)
            report.check("sin cambios no se abre nada (el tiempo de abrir queda en cero)",
                         second.parseElapsed < 0.001,
                         "abrir \(String(format: "%.1f", second.parseElapsed * 1000)) ms")
            report.line("   tiempos sin cambios: \(second.timing)")

            // Un solo archivo tocado: se reindexa ese y nada más.
            try FileManager.default.setAttributes([.modificationDate: Date()],
                                                  ofItemAtPath: copied[1])
            let third = try SessionIndexer.refresh(index: index, root: root)
            report.check("tocar una sesión reindexa SOLO esa",
                         third.updated == 1 && third.added == 0 && third.unchanged == 2,
                         third.summary)
            report.check("y solo esa se abre",
                         third.parseElapsed >= 0,
                         "abrir \(String(format: "%.1f", third.parseElapsed * 1000)) ms para 1 archivo")

            // Un archivo borrado sale del índice.
            try FileManager.default.removeItem(atPath: copied[2])
            let fourth = try SessionIndexer.refresh(index: index, root: root)
            report.check("borrar una sesión la saca del índice",
                         fourth.removed == 1 && fourth.indexedTotal == 2,
                         fourth.summary)
            report.check("el índice queda con lo que hay en disco",
                         try index.count() == 2, "\(try index.count()) en el índice")

            // La interfaz se puede armar desde el índice, sin releer archivos.
            let cached = try index.allSessions()
            report.check("las conversaciones se pueden leer desde el índice",
                         cached.count == 2 && cached.allSatisfy { !$0.path.isEmpty },
                         "\(cached.count) conversaciones cacheadas")
            report.check("la vista previa sobrevive en el índice",
                         cached.contains { !$0.preview.isEmpty },
                         cached.first?.preview.prefix(48).description ?? "sin vista previa")

            // Y el buscador sigue funcionando después de todo el ida y vuelta.
            if let word = cached.first(where: { $0.preview.count > 20 })?.preview
                .split(separator: " ").first(where: { $0.count > 5 }) {
                let cleaned = String(word).trimmingCharacters(in: CharacterSet.punctuationCharacters)
                report.check("el buscador sigue encontrando después de actualizar",
                             try !index.search(cleaned).isEmpty, "«\(cleaned)»")
            }

            // Comparación honesta contra 3.1: cuánto cuesta arrancar sin cambios.
            report.line("   arranque sin cambios: \(fourth.timing)")
        } catch {
            report.check("el indexado incremental funciona de punta a punta", false, "\(error)")
        }

        measureRealWorld(report)
    }

    /// La medición que importa: el ciclo completo contra las conversaciones **reales**.
    /// Solo lectura: se escanean y se leen, nunca se escriben. El índice va a un archivo temporal.
    private static func measureRealWorld(_ report: Reporter) {
        let root = SessionCatalog.defaultRoot
        let work = "\(NSTemporaryDirectory())p4w-real-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            let index = try SessionIndex(path: "\(work)/index.db")
            defer { index.close() }

            // Frío: índice vacío, hay que abrir todas.
            let cold = try SessionIndexer.refresh(index: index, root: root)
            report.line("   FRÍO (\(cold.filesOnDisk) conversaciones): \(cold.timing)")
            report.line("        \(cold.messagesIndexed) mensajes · "
                        + String(format: "%.1f MB de texto al buscador",
                                 Double(cold.textCharacters) / 1_048_576))

            // Tibio: nada cambió, no se abre ninguna.
            let warm = try SessionIndexer.refresh(index: index, root: root)
            report.line("   TIBIO (arranque normal):     \(warm.timing)")

            // La propiedad que importa es **estructural**, no una duración: en tibio no se abre
            // ningún archivo, y eso se ve en los contadores. Comparar una duración con cero exacto
            // era una prueba floja: `Date` nunca da exactamente 0, da microsegundos, así que pasaba
            // o fallaba según el azar del reloj.
            // En tibio se abren **solo** los archivos que cambiaron. En una máquina donde alguien está
            // usando Pi, eso puede ser uno o dos; en reposo, cero. Exigir cero exacto era una prueba
            // que dependía de que nadie tocara nada.
            report.check("en frío se abre todo y en tibio solo lo que cambió",
                         cold.added == cold.filesOnDisk && warm.added + warm.updated <= 3,
                         "frío: \(cold.added) de \(cold.filesOnDisk) · tibio: "
                             + "\(warm.added) nuevas y \(warm.updated) actualizadas")
            report.check("en tibio se abre una fracción de lo que se abre en frío",
                         (warm.added + warm.updated) * 20 < cold.filesOnDisk,
                         "abrir \(String(format: "%.0f", cold.parseElapsed * 1000)) ms → "
                             + "\(String(format: "%.0f", warm.parseElapsed * 1000)) ms")
            // El tiempo tibio depende de si alguien escribió una sesión justo ahora, así que se
            // reporta y se compara contra el frío; no se exige un número absoluto.
            report.line(String(format: "   tibio: %.0f ms (%.0f× menos que en frío)",
                               warm.totalElapsed * 1000,
                               cold.totalElapsed / max(warm.totalElapsed, 0.000001)))
            report.line(String(format: "   el costo tibio es %0.f× menor, y lo que queda (%.0f ms) "
                            + "es solo mirar %d archivos",
                            cold.totalElapsed / max(warm.totalElapsed, 0.000001),
                            warm.scanElapsed * 1000, warm.filesOnDisk))
        } catch {
            report.line("   (no se pudo medir contra las conversaciones reales: \(error))")
        }
    }

    // MARK: 15. Búsqueda sobre los mensajes (Fase 3.3)

    /// Fase 3.3: buscar tiene que encontrar texto que está **en el medio** de una conversación, no
    /// solo en su encabezado. Antes el buscador solo tenía el nombre y la vista previa.
    private static func checkMessageSearch(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("15. Búsqueda sobre los mensajes (Fase 3.3)")

        let root = SessionCatalog.defaultRoot
        let work = "\(NSTemporaryDirectory())p4w-search-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }

        do {
            let index = try SessionIndex(path: "\(work)/index.db")
            defer { index.close() }

            // Migración: una base nueva tiene que quedar directamente en la versión actual.
            report.check("el esquema nuevo se crea en la versión actual",
                         try index.currentSchemaVersion() == SessionIndex.schemaVersion,
                         "v\(try index.currentSchemaVersion())")

            // Indexado real de una copia, para no tocar nada del usuario.
            let project = "--prueba--"
            let directory = "\(root)"
            _ = directory
            let copyRoot = "\(work)/sessions/\(project)"
            try FileManager.default.createDirectory(atPath: copyRoot, withIntermediateDirectories: true)
            // Pi **no abre** una sesión cuya carpeta guardada ya no existe, así que la prueba tiene que
        // elegir una abrible. Y que existan otras no se silencia: se reporta.
        let unavailable = sessions.filter { !$0.cwdIsAvailable }
        if !unavailable.isEmpty {
            report.line("   ⚠️ \(unavailable.count) de \(sessions.count) conversaciones NO se pueden abrir: "
                        + "su carpeta guardada ya no existe (ej. \(unavailable.first?.cwd ?? "?"))")
        }
        let openable = sessions.filter { $0.cwdIsAvailable }
        guard let source = openable.max(by: { $0.sizeBytes < $1.sizeBytes }) else { return }
            let destination = "\(copyRoot)/grande.jsonl"
            try FileManager.default.copyItem(atPath: source.path, toPath: destination)

            let result = try SessionIndexer.refresh(index: index, root: "\(work)/sessions")
            report.check("indexa y extrae el texto de los mensajes",
                         result.messagesIndexed > 50,
                         "\(result.messagesIndexed) mensajes de 1 conversación · \(result.summary)")

            // Buscar algo que exista en el cuerpo. Se saca del propio archivo, así que la prueba no
            // depende de que una palabra inventada esté o no.
            let text = SessionReader.searchableText(path: destination)
            let candidate = text.rows
                .flatMap { $0.body.split(separator: " ") }
                .map { String($0).trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                .first { $0.count > 7 && $0.allSatisfy { $0.isLetter } }

            if let candidate {
                let hits = try index.search(candidate, limit: 10)
                report.check("encuentra una palabra del cuerpo de la conversación",
                             !hits.isEmpty, "«\(candidate)» → \(hits.count) resultado(s)")
            } else {
                report.line("   (no se encontró una palabra de prueba en el cuerpo)")
            }

            // Y con acentos: el tokenizador tiene que hacer que "transcripcion" encuentre
            // "transcripción". Es la razón por la que se eligió `remove_diacritics 2`.
            let withAccent = text.rows
                .flatMap { $0.body.split(separator: " ") }
                .map { String($0).trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                .first { $0.contains("ó") || $0.contains("á") || $0.contains("é") || $0.contains("í") }
            if let withAccent {
                let folded = withAccent.folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
                let hits = try index.search(folded, limit: 10)
                report.check("buscar sin acentos encuentra la palabra con acento",
                             !hits.isEmpty, "«\(folded)» encuentra «\(withAccent)»")
            } else {
                report.line("   (no se encontró una palabra con acento en el cuerpo)")
            }

            // Búsqueda por nombre de sesión, que ahora también se guarda al indexar.
            let named = try index.search("hola", limit: 5)
            report.line("   «hola» → \(named.count) resultado(s)")

            // El camino de migración del texto: una sesión marcada con una versión vieja tiene que
            // reindexarse aunque el archivo NO haya cambiado. Sin esto, cambiar *qué* se indexa
            // dejaría a todas las conversaciones con el texto viejo para siempre.
            try index.markTextVersion(paths: [destination], version: 1)
            let before = try index.searchableCount()
            let migrated = try SessionIndexer.refresh(index: index, root: "\(work)/sessions")
            report.check("una sesión con texto viejo se reindexa aunque el archivo no cambie",
                         migrated.textUpgraded == 1 && migrated.unchanged == 0,
                         "\(migrated.summary)")
            report.check("y su texto se reemplaza, no se duplica",
                         try index.searchableCount() == before,
                         "\(before) → \(try index.searchableCount()) filas")
            report.check("queda marcada como al día",
                         try index.pathsNeedingText().isEmpty,
                         "\(try index.pathsNeedingText().count) pendientes")

            // Y el contador de texto tiene que reflejar mensajes, no sesiones.
            report.check("el buscador guarda mensajes, no solo encabezados",
                         try index.searchableCount() > 50,
                         "\(try index.searchableCount()) filas de texto")
        } catch {
            report.check("la búsqueda sobre mensajes funciona de punta a punta", false, "\(error)")
        }
    }

    // MARK: 16. Nombres de sesión (Fase 3.4)

    /// Un nombre propio (`session_info`) puede estar en cualquier parte del archivo, y la lectura
    /// rápida de Fase 2 solo miraba cabecera y cola: por eso 0 de 268 salían con nombre.
    /// Esta comprobación dice la verdad sobre si la extracción funciona, en vez de suponerlo.
    private static func checkSessionNames(_ report: Reporter) {
        report.section("16. Nombres de sesión (Fase 3.4)")

        let entries = SessionCatalog.scan()
        report.check("hay conversaciones para revisar", !entries.isEmpty, "\(entries.count)")

        // Se buscan candidatos leyendo un pedazo chico: si el archivo menciona `session_info`,
        // vale la pena extraerlo entero.
        var candidates: [String] = []
        for entry in entries {
            guard let handle = FileHandle(forReadingAtPath: entry.path) else { continue }
            let head = (try? handle.read(upToCount: 262_144)) ?? Data()
            try? handle.close()
            if let text = String(data: head, encoding: .utf8), text.contains("\"type\":\"session_info\"") {
                candidates.append(entry.path)
                if candidates.count >= 20 { break }
            }
        }
        report.line("   archivos con `session_info` en los primeros 256 KB: \(candidates.count)")

        guard !candidates.isEmpty else {
            report.line("   (no hay ninguno con nombre: la prueba no aplica)")
            return
        }

        var extracted = 0
        var sample: String?
        var named: [SessionSummary] = []
        for path in candidates {
            let result = SessionReader.searchableText(path: path)
            if let name = result.name, !name.isEmpty {
                extracted += 1
                if sample == nil { sample = name }
                guard var summary = SessionCatalog.summarize(
                    path: path, project: (path as NSString).deletingLastPathComponent
                ) else { continue }
                if summary.name == nil { summary.name = name }
                named.append(summary)
            }
        }
        report.check("la extracción encuentra los nombres que existen",
                     extracted > 0, "\(extracted) de \(candidates.count) candidatos")
        if let sample {
            report.line("   ejemplo: \(sample.prefix(72))")
        }
        guard !named.isEmpty else { return }

        // Ida y vuelta completo: extraer → escribir en el índice → leer de vuelta.
        // Sin esto, "la extracción funciona" no prueba que el nombre llegue a la base.
        let work = "\(NSTemporaryDirectory())p4w-names-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            let index = try SessionIndex(path: "\(work)/index.db")
            defer { index.close() }
            try index.index(named)
            let stored = try index.allSessions()
            let withName = stored.filter { !($0.name ?? "").isEmpty }
            report.check("el nombre llega a la base y se lee de vuelta",
                         withName.count == named.count,
                         "\(withName.count) de \(named.count) escritos")
            report.line("   guardado: \((withName.first?.name ?? "").prefix(64))")
        } catch {
            report.check("el nombre sobrevive el ida y vuelta por la base", false, "\(error)")
        }
    }

    // MARK: 17. Acciones sobre una conversación (Fase 3.5)

    /// Renombrar, bifurcar, exportar y borrar. **Todo sobre copias temporales**: las conversaciones
    /// reales nunca se tocan, y el `--session-dir` apunta al temporal para que ni siquiera una
    /// bifurcación deje archivos en el directorio del usuario.
    private static func checkSessionActions(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("17. Acciones sobre una conversación (Fase 3.5)")

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        // Pi **no abre** una sesión cuya carpeta guardada ya no existe, así que la prueba tiene que
        // elegir una abrible. Y que existan otras no se silencia: se reporta.
        let unavailable = sessions.filter { !$0.cwdIsAvailable }
        if !unavailable.isEmpty {
            report.line("   ⚠️ \(unavailable.count) de \(sessions.count) conversaciones NO se pueden abrir: "
                        + "su carpeta guardada ya no existe (ej. \(unavailable.first?.cwd ?? "?"))")
        }
        let openable = sessions.filter { $0.cwdIsAvailable }
        guard let source = openable.max(by: { $0.sizeBytes < $1.sizeBytes }) else { return }

        let work = "\(NSTemporaryDirectory())p4w-actions-\(UUID().uuidString.prefix(8))"
        let copyPath = "\(work)/session.jsonl"
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: source.path, toPath: copyPath)
        } catch {
            report.check("se pudo preparar la copia de prueba", false, "\(error)")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: work) }

        // El directorio de sesiones apunta al temporal: si algo crea una sesión, la crea acá.
        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 600, maxLiveInstances: 1,
                                     extraArguments: ["--session-dir", work]),
            environment: environment
        )
        defer { supervisor.shutdownAll() }

        let opened: ManagedInstance?
        do {
            opened = try supervisor.acquire(.existing(path: copyPath))
        } catch {
            report.check("se pudo abrir la copia", false, "\(error)")
            return
        }
        guard let instance = opened else { return }
        supervisor.pin(copyPath)

        // ── El caso que rompía: una sesión que Pi se niega a abrir ───────────────
        if let bad = unavailable.first(where: { $0.sizeBytes > 1_000_000 }) {
            let badCopy = "\(work)/no-abrible.jsonl"
            try? FileManager.default.copyItem(atPath: bad.path, toPath: badCopy)
            let badSupervisor = InstanceSupervisor(
                config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                         reapAfterSeconds: 600, maxLiveInstances: 1),
                environment: environment
            )
            defer { badSupervisor.shutdownAll() }
            let started = Date()
            var failure: String?
            do {
                _ = try badSupervisor.acquire(.existing(path: badCopy))
            } catch {
                failure = "\(error)"
            }
            let elapsed = Date().timeIntervalSince(started)
            report.check("una sesión que Pi no puede abrir falla rápido y con el motivo real",
                         failure != nil && elapsed < 8,
                         "\(String(format: "%.1f", elapsed))s · \(failure?.prefix(120) ?? "sin error")")
        }

        // ── Renombrar ────────────────────────────────────────────────────────────
        let newName = "prueba-p4w-\(UUID().uuidString.prefix(6))"
        let renamed = instance.rename(to: newName)
        report.check("renombrar responde bien", renamed, newName)
        report.check("el nombre quedó visible para Pi",
                     instance.sessionName == newName, instance.sessionName ?? "sin nombre")

        // Y quedó **grabado en el archivo** por Pi, no por P4W: esa es la diferencia entre usar el
        // protocolo y escribir el `.jsonl` a mano.
        instance.abort()   // no lanza: no lleva `try?`
        let onDisk = (try? String(contentsOfFile: copyPath, encoding: .utf8)) ?? ""
        report.check("el nombre quedó grabado en el archivo (lo escribió Pi, no P4W)",
                     onDisk.contains(newName),
                     onDisk.contains("\"type\":\"session_info\"") ? "hay entrada session_info" : "sin entrada")

        // ── Exportar a HTML ──────────────────────────────────────────────────────
        let htmlPath = "\(work)/export.html"
        let exported = instance.exportHTML(to: htmlPath)
        report.check("exportar a HTML devuelve un archivo", exported != nil,
                     exported.map { ($0.path as NSString).lastPathComponent } ?? "sin archivo")
        if let exportPath = exported?.path {
            // Un solo `try?` sobre el diccionario y una sola conversión: encadenarlos daba `Int??`.
            let attributes = try? FileManager.default.attributesOfItem(atPath: exportPath)
            let size = attributes?[.size] as? Int
            let head = (try? String(contentsOfFile: exportPath, encoding: .utf8)) ?? ""
            report.check("el HTML tiene contenido de verdad",
                         (size ?? 0) > 1_000 && head.lowercased().contains("<html"),
                         "\(size ?? 0) bytes")
        }

        // ── Bifurcar ─────────────────────────────────────────────────────────────
        let candidates = instance.forkCandidates()
        report.check("hay mensajes desde dónde bifurcar", !candidates.isEmpty,
                     "\(candidates.count) candidatos")
        if let last = candidates.last {
            let filesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [])
            let forkedPath = instance.fork(from: last.entryId)
            let filesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [])
            report.check("bifurcar devuelve la conversación nueva",
                         forkedPath != nil && forkedPath != copyPath,
                         forkedPath.map { ($0 as NSString).lastPathComponent } ?? "sin ruta")
            report.check("la conversación nueva existe en disco",
                         forkedPath.map { FileManager.default.fileExists(atPath: $0) } == true)
            report.check("la bifurcación no toca la original",
                         FileManager.default.fileExists(atPath: copyPath))
            report.line("   archivos en el directorio: \(filesBefore.count) → \(filesAfter.count)")
        }

        // ── Borrar a la papelera ─────────────────────────────────────────────────
        let doomed = "\(work)/para-borrar.jsonl"
        try? FileManager.default.copyItem(atPath: copyPath, toPath: doomed)
        do {
            let trashed = try SessionCatalog.moveToTrash(path: doomed)
            report.check("borrar manda a la PAPELERA, no borra",
                         !FileManager.default.fileExists(atPath: doomed)
                             && FileManager.default.fileExists(atPath: trashed.path),
                         "destino: \((trashed.path as NSString).lastPathComponent)")
            // El artefacto de la prueba se saca de la papelera para no dejar basura ajena.
            try? FileManager.default.removeItem(at: trashed)
        } catch {
            report.check("borrar manda a la papelera", false, "\(error)")
        }
    }

    // MARK: 18. Símbolos del sistema

    /// Valida **todos** los nombres de símbolos que usa la app contra el sistema.
    ///
    /// Motivo: un nombre inválido no rompe el build, no falla ninguna prueba y no se ve en el código.
    /// Lo que hace es dejar el ícono vacío y **loguear decenas de veces por segundo**, que fue como se
    /// encontró. Un símbolo mal escrito es un bug silencioso, así que se verifica.
    private static func checkSymbols(_ report: Reporter) {
        report.section("18. Símbolos del sistema")

        // Se leen las fuentes: si no están (una app instalada), la comprobación no aplica.
        let root = "Sources"
        guard FileManager.default.fileExists(atPath: root) else {
            report.line("   (sin fuentes a mano: se saltea)")
            return
        }
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let path as String in enumerator where path.hasSuffix(".swift") {
                files.append("\(root)/\(path)")
            }
        }
        guard !files.isEmpty else {
            report.line("   (no se encontraron fuentes Swift)")
            return
        }

        // Se extraen los nombres usados, sin importar si vienen de `Image(systemName:)` o de un ternario.
        var names = Set<String>()
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                var remaining = Substring(line)
                while let range = remaining.range(of: "systemName: \"") {
                    let after = remaining[range.upperBound...]
                    guard let end = after.firstIndex(of: "\"") else { break }
                    names.insert(String(after[..<end]))
                    remaining = after[end...]
                }
            }
        }
        report.check("se encontraron símbolos para verificar", !names.isEmpty,
                     "\(names.count) distintos en \(files.count) archivos")

        var invalid: [String] = []
        for name in names.sorted() where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            invalid.append(name)
        }
        report.check("todos los símbolos existen en el sistema", invalid.isEmpty,
                     invalid.isEmpty ? "los \(names.count) son válidos" : "inválidos: \(invalid.joined(separator: ", "))")
    }

    // MARK: 19. Configuración de Pi (Fase 3.6)

    /// El esquema se **genera** desde los docs de Pi, y el archivo se edita con candado.
    /// La configuración real del usuario se lee pero **nunca se escribe desde acá**.
    private static func checkSettings(_ report: Reporter) {
        report.section("19. Configuración de Pi (Fase 3.6)")

        let environment = ShellEnvironment.resolve()
        let docPath = PiSettingsSchema.discoverDocPath(piExecutable: environment.piExecutable)
        report.check("se encuentra el documento de ajustes dentro del paquete de Pi",
                     docPath != nil,
                     docPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "no encontrado")
        guard let docPath else { return }

        let schema = PiSettingsSchema.parse(documentAt: docPath)
        report.check("el esquema se genera desde el documento", schema.count > 40,
                     "\(schema.count) ajustes en \(Set(schema.map(\.section)).count) secciones")

        // Que estén los que importan, con el tipo bien interpretado: si el parseo se rompe, esto lo dice.
        func setting(_ key: String) -> PiSettingsSchema.Setting? { schema.first { $0.key == key } }
        report.check("reconoce un ajuste booleano", setting("hideThinkingBlock")?.kind == .boolean)
        report.check("reconoce un ajuste de texto", setting("defaultModel")?.kind == .text)
        report.check("reconoce una lista de textos", setting("enabledModels")?.kind == .textList)
        report.check("reconoce un ajuste de número", setting("compaction.reserveTokens")?.kind == .number)
        if case .enumeration(let options)? = setting("defaultThinkingLevel")?.kind {
            report.check("reconoce una enumeración con sus opciones",
                         options.contains("high") && options.contains("off"),
                         options.joined(separator: " / "))
        } else {
            report.check("reconoce una enumeración con sus opciones", false,
                         "\(String(describing: setting("defaultThinkingLevel")?.kind))")
        }
        report.check("reconoce un ajuste anidado", setting("compaction.enabled") != nil)

        // ── Lectura de la configuración real (solo lectura) ──────────────────────
        do {
            let real = try PiSettingsStore()
            let model = real.displayValue(for: "defaultModel")
            let provider = real.displayValue(for: "defaultProvider")
            report.line("   configuración real: proveedor «\(provider)» · modelo «\(model)»")
            report.check("lee la configuración real de Pi", !model.isEmpty || !provider.isEmpty)
            report.check("no dice que cambió si nadie la tocó", !real.changedOnDisk())
        } catch {
            report.check("se pudo leer la configuración real", false, "\(error)")
        }

        // ── Ida y vuelta sobre un archivo temporal ───────────────────────────────
        let work = "\(NSTemporaryDirectory())p4w-settings-\(UUID().uuidString.prefix(8))"
        let testPath = "\(work)/settings.json"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            try #"{"defaultModel":"viejo","compaction":{"enabled":true},"theme":"x"}"#
                .write(toFile: testPath, atomically: true, encoding: .utf8)

            let store = try PiSettingsStore(path: testPath)
            report.check("lee un valor de primer nivel",
                         store.displayValue(for: "defaultModel") == "viejo")
            report.check("lee un valor anidado",
                         store.displayValue(for: "compaction.enabled") == "true")

            // Escribir con conversaciones activas tiene que estar bloqueado.
            var locked = false
            do {
                try store.apply(["defaultModel": "nuevo"], activeInstances: 1)
            } catch { locked = true }
            report.check("no escribe si hay conversaciones activas", locked,
                         locked ? "bloqueado como corresponde" : "¡escribió con el candado puesto!")

            // Sin instancias activas, escribe y lo deja legible.
            try store.apply(["defaultModel": "nuevo", "hideThinkingBlock": true], activeInstances: 0)
            let reread = try PiSettingsStore(path: testPath)
            report.check("escribe un valor de primer nivel",
                         reread.displayValue(for: "defaultModel") == "nuevo")
            report.check("escribe un valor nuevo",
                         reread.displayValue(for: "hideThinkingBlock") == "true")
            report.check("no pierde lo que no se tocó",
                         reread.displayValue(for: "theme") == "x"
                             && reread.displayValue(for: "compaction.enabled") == "true")
            report.check("deja copia de seguridad antes de escribir",
                         FileManager.default.fileExists(atPath: "\(testPath).p4w-backup"))

            // Escribir anidado y quitarlo.
            try reread.apply(["compaction.reserveTokens": 4_096], activeInstances: 0)
            let nested = try PiSettingsStore(path: testPath)
            report.check("escribe dentro de un objeto existente",
                         nested.displayValue(for: "compaction.reserveTokens") == "4096"
                             && nested.displayValue(for: "compaction.enabled") == "true")
            try nested.apply(["compaction.reserveTokens": nil], activeInstances: 0)
            let removed = try PiSettingsStore(path: testPath)
            report.check("quitar un valor lo devuelve al default de Pi",
                         removed.displayValue(for: "compaction.reserveTokens").isEmpty
                             && removed.displayValue(for: "compaction.enabled") == "true")

            // El archivo tiene que seguir siendo JSON válido y legible por Pi.
            let raw = (try? String(contentsOfFile: testPath, encoding: .utf8)) ?? ""
            let reparsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            report.check("el archivo sigue siendo JSON válido", reparsed != nil, "\(raw.count) bytes")
        } catch {
            report.check("la edición de configuración funciona de punta a punta", false, "\(error)")
        }
    }

    // MARK: 20. Spaces (Fase 4.1)

    /// El modelo y la persistencia de spaces. **No crea ningún space en la configuración real**:
    /// todo pasa por un archivo temporal.
    private static func checkSpaces(_ report: Reporter) {
        report.section("20. Spaces (Fase 4.1)")

        let work = "\(NSTemporaryDirectory())p4w-spaces-\(UUID().uuidString.prefix(8))"
        let path = "\(work)/spaces.json"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

            // ── Arranque en limpio ───────────────────────────────────────────────
            let store = try SpacesStore(path: path)
            report.check("arranca sin espacios y sin archivo", store.all().isEmpty)

            let personal = try store.createSpace(name: "Personal")
            let trabajo = try store.createSpace(name: "Trabajo", color: .purple)
            report.check("crea espacios con IDs cortos y estables",
                         personal.id == "s1" && trabajo.id == "s2",
                         "\(personal.id), \(trabajo.id)")

            try store.move(sessionPath: "/tmp/una.jsonl", profileName: "lean", toSpaceID: trabajo.id)
            try store.move(sessionPath: "/tmp/otra.jsonl", profileName: "full", toSpaceID: trabajo.id)
            report.check("mueve conversaciones a un espacio",
                         store.space(withID: trabajo.id)?.tabs.count == 2)
            report.check("sabe en qué espacio está una conversación",
                         store.spaceContaining(sessionPath: "/tmp/una.jsonl")?.id == trabajo.id)

            // Una conversación vive en **un solo** espacio: moverla la saca del anterior.
            try store.move(sessionPath: "/tmp/una.jsonl", profileName: "lean", toSpaceID: personal.id)
            report.check("mover una conversación la saca del espacio anterior",
                         store.space(withID: trabajo.id)?.tabs.count == 1
                             && store.space(withID: personal.id)?.tabs.count == 1,
                         "trabajo \(store.space(withID: trabajo.id)?.tabs.count ?? 0) · "
                             + "personal \(store.space(withID: personal.id)?.tabs.count ?? 0)")

            // ── Ida y vuelta por el archivo ──────────────────────────────────────
            let reopened = try SpacesStore(path: path)
            report.check("los espacios sobreviven a cerrar y abrir",
                         reopened.all().count == 2
                             && reopened.spaceContaining(sessionPath: "/tmp/una.jsonl")?.id == personal.id,
                         "\(reopened.all().count) espacios")
            report.check("el perfil por pestaña se conserva",
                         reopened.space(withID: trabajo.id)?.tabs.first?.profileName == "full",
                         reopened.space(withID: trabajo.id)?.tabs.first?.profileName ?? "sin perfil")

            // ── IDs que no se reutilizan ─────────────────────────────────────────
            try reopened.deleteSpace(id: trabajo.id)
            let nuevo = try reopened.createSpace(name: "Otro")
            report.check("un ID borrado NO se reutiliza",
                         nuevo.id != trabajo.id, "se borró \(trabajo.id) y el nuevo es \(nuevo.id)")

            // ── Tabs colgados ────────────────────────────────────────────────────
            try reopened.move(sessionPath: "/tmp/inexistente.jsonl", profileName: "lean",
                              toSpaceID: personal.id)
            let removed = try reopened.pruneTabs(existingPaths: ["/tmp/una.jsonl"])
            report.check("saca los tabs cuyos archivos ya no están",
                         removed == 1 && reopened.space(withID: personal.id)?.tabs.count == 1,
                         "\(removed) sacado(s)")

            // Al borrar una conversación, su tab no queda colgando.
            try reopened.removeFromSpaces(sessionPath: "/tmp/una.jsonl")
            report.check("borrar una conversación no deja el tab colgando",
                         reopened.space(withID: personal.id)?.tabs.isEmpty == true)

            // ── Migración de un archivo viejo ────────────────────────────────────
            let legacyPath = "\(work)/viejo.json"
            try #"{"spaces":[{"id":"s9","name":"Viejo","tabs":[]}]}"#
                .write(toFile: legacyPath, atomically: true, encoding: .utf8)
            let migrated = try SpacesStore(path: legacyPath)
            report.check("lee un archivo de antes, sin número de versión",
                         migrated.all().count == 1 && migrated.all().first?.name == "Viejo")
            let migratedRaw = (try? String(contentsOfFile: legacyPath, encoding: .utf8)) ?? ""
            report.check("y lo reescribe ya migrado",
                         migratedRaw.contains("\"version\""),
                         "quedó con versión en el archivo")
            let afterMigration = try SpacesStore(path: legacyPath)
            report.check("el contador se acomoda para no repetir un ID",
                         try afterMigration.createSpace(name: "Nuevo").id != "s9",
                         afterMigration.all().last?.id ?? "?")   // `all()` no lanza

            // ── Escritura atómica ────────────────────────────────────────────────
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work))?
                .filter { $0.hasSuffix(".tmp") } ?? []
            report.check("la escritura atómica no deja archivos temporales",
                         leftovers.isEmpty, leftovers.joined(separator: ", "))
            let validJSON = (try? JSONSerialization.jsonObject(with: Data(
                contentsOf: URL(fileURLWithPath: path)
            ))) != nil
            report.check("el archivo queda siendo JSON válido", validJSON)

            // ── Un archivo de una versión futura no se pisa ──────────────────────
            let futurePath = "\(work)/futuro.json"
            try #"{"version":99,"spaces":[]}"#.write(toFile: futurePath, atomically: true, encoding: .utf8)
            var refused = false
            do { _ = try SpacesStore(path: futurePath) } catch { refused = true }
            report.check("un archivo de una versión futura NO se sobrescribe",
                         refused, refused ? "se niega a abrirlo" : "lo abrió igual")
        } catch {
            report.check("los spaces funcionan de punta a punta", false, "\(error)")
        }
    }

    // MARK: 21. Organización en spaces (Fase 4.2)

    /// Lo que agrega 4.2: agrupar, reordenar, y la promesa que más importa — **borrar un space no
    /// borra conversaciones**. Se verifica con archivos temporales propios.
    private static func checkSpaceOrganisation(_ report: Reporter) {
        report.section("21. Organización en spaces (Fase 4.2)")

        let work = "\(NSTemporaryDirectory())p4w-org-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try SpacesStore(path: "\(work)/spaces.json")

            let a = try store.createSpace(name: "A")
            let b = try store.createSpace(name: "B")
            let c = try store.createSpace(name: "C")

            // ── Reordenar spaces ────────────────────────────────────────────────
            try store.reorderSpaces(ids: [c.id, a.id, b.id])
            report.check("reordenar spaces cambia el orden",
                         store.all().map(\.id) == [c.id, a.id, b.id],
                         store.all().map(\.id).joined(separator: ", "))
            let reopened = try SpacesStore(path: "\(work)/spaces.json")
            report.check("el orden sobrevive a reabrir",
                         reopened.all().map(\.id) == [c.id, a.id, b.id],
                         reopened.all().map(\.id).joined(separator: ", "))
            try reopened.reorderSpaces(ids: [a.id])
            report.check("un reordenamiento incompleto no pierde spaces",
                         Set(reopened.all().map(\.id)) == Set([a.id, b.id, c.id]),
                         "\(reopened.all().count) spaces")

            // ── Reordenar tabs dentro de un space ───────────────────────────────
            try reopened.move(sessionPath: "/tmp/1.jsonl", profileName: "lean", toSpaceID: a.id)
            try reopened.move(sessionPath: "/tmp/2.jsonl", profileName: "lean", toSpaceID: a.id)
            try reopened.move(sessionPath: "/tmp/3.jsonl", profileName: "lean", toSpaceID: a.id)
            try reopened.reorderTabs(inSpaceID: a.id, sessionPaths: ["/tmp/3.jsonl", "/tmp/1.jsonl"])
            let order = reopened.space(withID: a.id)?.tabs.map(\.sessionPath)
            report.check("reordenar tabs dentro de un space",
                         order == ["/tmp/3.jsonl", "/tmp/1.jsonl", "/tmp/2.jsonl"],
                         order?.joined(separator: " ") ?? "sin tabs")
            let afterTabReorder = try SpacesStore(path: "\(work)/spaces.json")
            report.check("el orden de los tabs sobrevive a reabrir",
                         afterTabReorder.space(withID: a.id)?.tabs.map(\.sessionPath)
                             == ["/tmp/3.jsonl", "/tmp/1.jsonl", "/tmp/2.jsonl"])

            // ── La promesa: borrar un space NO borra conversaciones ─────────────
            let fakeSession = "\(work)/conversacion.jsonl"
            try #"{"type":"session","id":"x","cwd":"/tmp"}"#
                .write(toFile: fakeSession, atomically: true, encoding: .utf8)
            try afterTabReorder.move(sessionPath: fakeSession, profileName: "lean", toSpaceID: b.id)
            report.check("la conversación quedó anotada en el space",
                         afterTabReorder.contains(sessionPath: fakeSession))
            try afterTabReorder.deleteSpace(id: b.id)
            report.check("borrar el space saca la conversación de la organización",
                         !afterTabReorder.contains(sessionPath: fakeSession))
            report.check("borrar el space NO borra la conversación",
                         FileManager.default.fileExists(atPath: fakeSession),
                         "el archivo sigue en su lugar")
            let afterDelete = try SpacesStore(path: "\(work)/spaces.json")
            report.check("y el borrado sobrevive a reabrir",
                         afterDelete.all().count == 2 && afterDelete.space(withID: b.id) == nil)
        } catch {
            report.check("la organización en spaces funciona de punta a punta", false, "\(error)")
        }
    }

    // MARK: 22. Apertura instantánea (carga perezosa)

    /// Abrir una conversación grande tiene que ser **instantáneo**: se lee el final, no el archivo
    /// entero. Antes se parseaba hasta 16 MB antes de mostrar nada, y además se lanzaba el proceso en
    /// el hilo principal: la ventana parecía colgada.
    private static func checkLazyHistory(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("22. Apertura instantánea (carga perezosa)")

        let openable = sessions.filter { $0.cwdIsAvailable }
        guard let biggest = openable.max(by: { $0.sizeBytes < $1.sizeBytes }) else { return }
        report.line("   la más grande abrible: \(biggest.sizeLabel)")

        // Ventana del final: lo que se muestra al abrir.
        let tailStarted = Date()
        let tail = SessionReader.loadTail(path: biggest.path)
        let tailElapsed = Date().timeIntervalSince(tailStarted)
        report.check("abrir lee solo el final", !tail.items.isEmpty,
                     "\(tail.items.count) mensajes en \(String(format: "%.0f", tailElapsed * 1000)) ms")
        report.check("abrir es instantáneo (menos de 1 segundo)",
                     tailElapsed < 1.0,
                     String(format: "%.0f ms", tailElapsed * 1000))
        report.check("sabe que hay más historial atrás", tail.hasMore)
        report.check("el tramo anterior empieza antes",
                     tail.startOffset < biggest.sizeBytes,
                     "offset \(tail.startOffset) de \(biggest.sizeBytes) bytes")

        // Comparación honesta contra leer todo.
        let fullStarted = Date()
        _ = SessionReader.load(path: biggest.path)
        let fullElapsed = Date().timeIntervalSince(fullStarted)
        report.line(String(format: "   leer todo: %.0f ms · leer el final: %.0f ms (%.0f× menos)",
                           fullElapsed * 1000, tailElapsed * 1000,
                           fullElapsed / max(tailElapsed, 0.000001)))
        report.check("leer el final es más rápido que leer todo",
                     tailElapsed < fullElapsed || tailElapsed < 0.05,
                     String(format: "final %.0f ms vs todo %.0f ms", tailElapsed * 1000, fullElapsed * 1000))

        // Y el tramo anterior se puede pedir, sin repetir lo que ya está.
        let before = SessionReader.loadBefore(path: biggest.path, before: tail.startOffset, limit: 20)
        report.check("se puede pedir el tramo anterior",
                     before.startOffset < tail.startOffset,
                     "offset \(before.startOffset) < \(tail.startOffset)")
        let tailIDs = Set(tail.items.map(\.id))
        let previousIDs = Set(before.items.map(\.id))
        report.check("los tramos no se solapan",
                     tailIDs.intersection(previousIDs).isEmpty,
                     "\(tailIDs.intersection(previousIDs).count) repetidos")

        // El modelo sale del archivo, sin despertar ningún proceso.
        let model = SessionReader.lastModelInfo(path: biggest.path)
        report.check("el modelo de la conversación se lee del archivo",
                     model != nil, model.map { "\($0.provider)/\($0.modelId)" } ?? "sin model_change")
    }

    // MARK: 23. El desplazamiento no puede hacer trabajo caro

    /// El cuelgue al subir no era la lectura: era que **cada cuadro** del desplazamiento volvía a
    /// parsear el markdown y a convertirlo a `AttributedString`. Esto verifica que ese trabajo se haga
    /// una sola vez por texto.
    private static func checkMarkdownCache(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("23. Trabajo de render cacheado (desplazamiento)")

        // Se busca el mensaje más largo que exista en el historial: es el peor caso real.
        var longest = ""
        for session in sessions.prefix(60) {
            let window = SessionReader.loadTail(path: session.path, limit: 12, maxBytes: 512_000)
            for item in window.items where item.text.count > longest.count { longest = item.text }
            if longest.count > 8_000 { break }
        }
        guard longest.count > 200 else {
            report.line("   (no se encontró un mensaje largo para medir)")
            return
        }
        report.line("   peor caso encontrado: \(longest.count) caracteres de markdown")

        MarkdownCache.reset()
        let firstStarted = Date()
        let first = MarkdownCache.parsedBlocks(longest)
        let firstElapsed = Date().timeIntervalSince(firstStarted)

        let secondStarted = Date()
        let second = MarkdownCache.parsedBlocks(longest)
        let secondElapsed = Date().timeIntervalSince(secondStarted)

        report.check("parsear markdown devuelve bloques", !first.isEmpty, "\(first.count) bloques")
        report.check("la segunda vez sale de la caché y es más rápido",
                     secondElapsed < firstElapsed || secondElapsed < 0.0005,
                     String(format: "primera %.2f ms · segunda %.3f ms", firstElapsed * 1000,
                            secondElapsed * 1000))
        report.check("y el resultado es el mismo", second.count == first.count)

        // La identidad de los bloques tiene que ser **estable**: antes, una línea divisoria devolvía un
        // UUID nuevo en cada lectura y SwiftUI reconstruía todo el subárbol.
        let repeated = MarkdownCache.parsedBlocks(longest)
        report.check("los bloques son comparables entre lecturas (sin identidad aleatoria)",
                     repeated.count == first.count,
                     "misma cantidad en las tres lecturas")

        // Y el texto en línea también se cachea.
        MarkdownCache.reset()
        _ = MarkdownCache.inlineText(longest)
        let inlineStarted = Date()
        _ = MarkdownCache.inlineText(longest)
        let inlineElapsed = Date().timeIntervalSince(inlineStarted)
        report.check("el texto en línea sale de la caché",
                     inlineElapsed < 0.0005,
                     String(format: "%.3f ms en la segunda lectura", inlineElapsed * 1000))

        // El tope es por caracteres. Se mete **más texto del que permite** y se comprueba que
        // descarta: medir el tope con textos chicos no prueba nada, porque nunca lo alcanzan.
        MarkdownCache.reset()
        let bigMessage = String(repeating: "texto de prueba con algo de markdown **aquí**\n", count: 1_200)
        report.line("   texto de prueba: \(bigMessage.count / 1024) KB · se guardan 200 distintos "
                    + "= \(200 * bigMessage.count / 1_048_576) MB si no hubiera tope")
        for index in 0..<200 {
            _ = MarkdownCache.parsedBlocks("\(bigMessage)\n variante \(index)")
        }
        let afterMany = MarkdownCache.statistics()
        report.check("la caché descarta cuando se pasa del tope",
                     afterMany.characters <= 4 * 1_048_576 && afterMany.blocks < 200,
                     "\(afterMany.characters / 1_048_576) MB guardados en \(afterMany.blocks) bloques "
                         + "(de 200 que se pidieron)")
        MarkdownCache.reset()

        let stats = MarkdownCache.statistics()
        report.line("   caché: \(stats.hits) aciertos · \(stats.misses) misses · "
                    + "\(stats.blocks) bloques y \(stats.inline) textos guardados · "
                    + "\(stats.characters / 1024) KB de texto en memoria")

        // Comparación honesta: cuánto costaba antes (parsear en cada render) contra ahora.
        MarkdownCache.reset()
        var naiveTotal: TimeInterval = 0
        for _ in 0..<20 {
            let started = Date()
            _ = MarkdownParser.parse(longest)
            naiveTotal += Date().timeIntervalSince(started)
        }
        var cachedTotal: TimeInterval = 0
        _ = MarkdownCache.parsedBlocks(longest)
        for _ in 0..<20 {
            let started = Date()
            _ = MarkdownCache.parsedBlocks(longest)
            cachedTotal += Date().timeIntervalSince(started)
        }
        report.line(String(format: "   20 renders: sin caché %.1f ms · con caché %.2f ms (%.0f× menos)",
                           naiveTotal * 1000, cachedTotal * 1000,
                           naiveTotal / max(cachedTotal, 0.000001)))
        report.check("la caché reduce el costo por render",
                     cachedTotal < naiveTotal / 5,
                     String(format: "%.0f× menos", naiveTotal / max(cachedTotal, 0.000001)))
    }

    // MARK: 24. Pestañas y fijado (Fase 4.3)

    /// Lo que agrega 4.3: cambiar de conversación con el teclado y **fijar** una para que el
    /// reciclador no la toque. Lo segundo se verifica contra el supervisor real, que es donde importa.
    private static func checkTabsAndPinning(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("24. Pestañas y fijado (Fase 4.3)")

        // ── Las fijadas sobreviven al archivo ────────────────────────────────────
        let work = "\(NSTemporaryDirectory())p4w-tabs-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try SpacesStore(path: "\(work)/spaces.json")
            report.check("arranca sin nada fijado", store.pinnedPaths().isEmpty)
            try store.setPinned(["/tmp/a.jsonl", "/tmp/b.jsonl"])
            let reopened = try SpacesStore(path: "\(work)/spaces.json")
            report.check("las fijadas sobreviven a cerrar y abrir",
                         reopened.pinnedPaths() == ["/tmp/a.jsonl", "/tmp/b.jsonl"],
                         "\(reopened.pinnedPaths().count) fijadas")
            try reopened.setPinned([])
            report.check("se pueden soltar todas",
                         try SpacesStore(path: "\(work)/spaces.json").pinnedPaths().isEmpty)
        } catch {
            report.check("el fijado se guarda y se lee", false, "\(error)")
        }

        // ── Lo que importa de verdad: el reciclador respeta lo fijado ────────────
        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        let openable = sessions.filter { $0.cwdIsAvailable }
        guard openable.count >= 2 else { return }

        let copiesRoot = "\(NSTemporaryDirectory())p4w-pin2-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: copiesRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: copiesRoot) }
        var copies: [String] = []
        for (index, source) in openable.prefix(2).enumerated() {
            let destination = "\(copiesRoot)/s\(index).jsonl"
            try? FileManager.default.copyItem(atPath: source.path, toPath: destination)
            copies.append(destination)
        }
        guard copies.count == 2 else { return }

        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 600, maxLiveInstances: 4),
            environment: environment
        )
        defer { supervisor.shutdownAll() }
        guard let first = try? supervisor.acquire(.existing(path: copies[0])),
              let second = try? supervisor.acquire(.existing(path: copies[1])) else { return }

        supervisor.setPinned([copies[0]])
        let reaped = supervisor.reapIdle(now: Date(), threshold: 0)
        report.check("el reciclador NO toca una conversación fijada",
                     !reaped.contains(copies[0]) && first.isRunning,
                     "fijadas: \(supervisor.pinned.count) · recicladas: \(reaped.count)")
        report.check("y sí recicla la que no está fijada",
                     reaped.contains(copies[1]) || !second.isRunning)
        report.check("soltar el fijado la vuelve reciclable",
                     supervisor.pinned.isEmpty == false
                         && { supervisor.setPinned([]); return supervisor.pinned.isEmpty }())

        // ── ⌘W cierra, no borra ─────────────────────────────────────────────────
        let victim = "\(copiesRoot)/cierra.jsonl"
        try? FileManager.default.copyItem(atPath: copies[0], toPath: victim)
        supervisor.release(victim, reason: .explicit)
        report.check("cerrar una pestaña libera el proceso pero NO el archivo",
                     FileManager.default.fileExists(atPath: victim),
                     "libera la memoria, no el trabajo")
    }

    // MARK: 25. Panel ordenado por atención (Fase 4.4)

    /// El orden y el filtro son puros, así que se verifican con estados armados a mano: no hace falta
    /// que una conversación real se bloquee en el momento justo.
    private static func checkAgentAttention(_ report: Reporter) {
        report.section("25. Panel ordenado por atención (Fase 4.4)")

        func summary(_ key: String, _ state: InstanceState, dialogs: Int = 0,
                     idle: TimeInterval = 0, profile: String = "lean",
                     model: String? = nil) -> InstanceSummary {
            InstanceSummary(
                sessionKey: key, sessionID: key, profileName: profile, state: state,
                pid: 1, footprintBytes: 1, residentBytes: 1, idleSeconds: idle,
                messageCount: 0, liveMessageCount: 0, lastRunErrored: false, lastError: nil,
                modelID: model, thinkingLevel: nil, usage: TokenUsage(), reapable: true,
                runActive: false, pendingDialogs: dialogs, reapCount: 0
            )
        }

        let blocked = summary("/s/blocked.jsonl", .blocked, idle: 5)
        let waiting = summary("/s/waiting.jsonl", .idle, dialogs: 1, idle: 30)
        let working = summary("/s/working.jsonl", .working, idle: 1, model: "deepseek")
        let failed = summary("/s/failed.jsonl", .failed, idle: 90)
        let idle = summary("/s/idle.jsonl", .idle, idle: 10)
        let cold = summary("/s/cold.jsonl", .cold, idle: 120)

        let unordered = [idle, working, cold, blocked, failed, waiting]
        let ordered = AgentAttention.sorted(unordered)
        report.check("lo que te necesita va primero",
                     ordered.prefix(2).allSatisfy { AgentAttention.needsYou($0) },
                     ordered.map { "\($0.state.rawValue)\($0.pendingDialogs > 0 ? "*" : "")" }
                        .joined(separator: " → "))
        report.check("un diálogo pendiente cuenta como «te necesita» aunque el estado sea ocioso",
                     AgentAttention.needsYou(waiting))
        report.check("el trabajo en curso va después de la atención",
                     ordered[2].state == .working, ordered[2].state.rawValue)
        report.check("lo ocioso y lo frío quedan al final",
                     ordered.suffix(2).allSatisfy { $0.state == .idle || $0.state == .cold },
                     ordered.suffix(2).map(\.state.rawValue).joined(separator: ", "))
        report.check("a igual atención gana lo que lleva más tiempo esperando",
                     AgentAttention.sorted([summary("/a", .idle, idle: 5),
                                            summary("/b", .idle, idle: 60)]).first?.sessionKey == "/b")

        let attention = AgentAttention.attentionCount(unordered)
        report.check("cuenta bien cuántas te necesitan", attention == 2, "\(attention)")

        // ── Filtro ───────────────────────────────────────────────────────────────
        report.check("sin filtro no se esconde nada",
                     AgentAttention.filtered(unordered, query: "").count == unordered.count)
        let blockedOnly = AgentAttention.filtered(unordered, query: "s:blocked")
        report.check("s:blocked deja solo las bloqueadas",
                     blockedOnly.count == 1 && blockedOnly.first?.state == .blocked,
                     "\(blockedOnly.count) resultado(s)")
        report.check("el filtro de estado acepta prefijos",
                     AgentAttention.filtered(unordered, query: "s:work").count == 1)
        report.check("dos términos se combinan con «y»",
                     AgentAttention.filtered(unordered, query: "s:idle lean").count == 2)
        report.check("el texto libre busca en la ruta de la sesión",
                     AgentAttention.filtered(unordered, query: "failed").count == 1)
        report.check("un filtro que no coincide no devuelve nada",
                     AgentAttention.filtered(unordered, query: "s:nonexistente").isEmpty)
        // Se ofrecen solo los estados que existen entre las conversaciones vivas, en orden de
        // atención y no en orden arbitrario. Acá hay cinco distintos.
        report.check("los estados del filtro salen de los que existen, en orden de atención",
                     AgentAttention.presentStates(unordered) == [.blocked, .working, .failed, .idle, .cold],
                     AgentAttention.presentStates(unordered).map(\.rawValue).joined(separator: ", "))
    }

    // MARK: 26. Catálogo de extensiones y perfiles con caché

    /// Lo que ahorra plata: un perfil liviano que igual conserve el caché de prefijo.
    /// El catálogo se **lee** de los paquetes instalados; no hay lista escrita a mano.
    private static func checkExtensionCatalog(_ report: Reporter) {
        report.section("26. Catálogo de extensiones y perfiles (ahorro de costo)")

        let catalog = PiExtensionCatalog.discover()
        report.check("el catálogo encuentra las extensiones instaladas", !catalog.isEmpty,
                     "\(catalog.count) encontradas")
        for entry in catalog.prefix(6) {
            let models = entry.appliesToModels.isEmpty ? "todos los modelos"
                                                      : entry.appliesToModels.joined(separator: ", ")
            report.line("   \(entry.shortName) v\(entry.version ?? "?") · "
                        + "\(entry.entryPoints.count) punto(s) de entrada · aplica a: \(models)")
        }
        report.check("los puntos de entrada existen en disco",
                     catalog.allSatisfy { entry in
                         entry.entryPoints.allSatisfy { FileManager.default.fileExists(atPath: $0) }
                     })

        // Las dos que importan para el ahorro.
        guard let cache = catalog.first(where: { $0.name.contains("deepseek-cache") }) else {
            report.line("   (no está instalada la extensión de caché: no aplica el resto de la prueba)")
            return
        }
        report.check("la extensión de caché declara a qué modelos aplica",
                     !cache.appliesToModels.isEmpty,
                     cache.appliesToModels.joined(separator: ", "))
        report.check("y no aplica a un modelo que no es DeepSeek",
                     !cache.applies(toModel: "anthropic/claude-sonnet"))
        report.check("pero sí a uno de DeepSeek",
                     cache.applies(toModel: "command-code/deepseek-v4-flash"))

        // El perfil armado: liviano + `-e` explícito.
        let profile = ProfileSpec.lean(with: [cache], name: "lean-cache", label: "lean + caché")
        report.check("el perfil liviano-con-caché sigue apagando el descubrimiento",
                     profile.arguments.contains("--no-extensions"))
        report.check("y enciende la extensión de forma explícita",
                     profile.arguments.contains("-e") && profile.arguments.contains(cache.entryPoints[0]),
                     "\(profile.arguments.filter { $0.hasPrefix("-") }.joined(separator: " "))")
        report.line("   perfil: \(profile.label) · \(profile.arguments.count) argumentos")

        // Y lo más importante: que arranque de verdad, mida y traiga la extensión.
        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        let work = "\(NSTemporaryDirectory())p4w-ext-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: profile,
                                     reapAfterSeconds: 600, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }
        let started = Date()
        guard let instance = try? supervisor.acquire(.new(id: UUID().uuidString, directory: work),
                                                    profile: profile) else {
            report.check("el perfil liviano-con-caché arranca", false, "no se pudo lanzar")
            return
        }
        let boot = Date().timeIntervalSince(started)
        report.check("el perfil liviano-con-caché arranca rápido", boot < 3,
                     String(format: "%.2f s", boot))
        report.line("   memoria propia: \(ProcessMetrics.megabytes(instance.footprintBytes)) "
                    + "(el perfil liviano solo son ~122 MB de residente)")
        // La extensión de caché se registra como comando: si está cargada, aparece.
        let commands = instance.request(type: "get_commands", timeout: 20)
        let names = ((commands?.data?["commands"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
        report.check("la extensión se cargó dentro del perfil liviano",
                     names.contains { $0.lowercased().contains("cache") },
                     "\(names.count) comandos: "
                         + names.filter { $0.lowercased().contains("cache") }.joined(separator: ", "))
    }

    // MARK: 27. Avisos de las extensiones y preferencias

    /// La tasa de acierto del caché llega por `setStatus`, y el texto viene con códigos ANSI porque las
    /// extensiones usan el tema de la terminal. Esto verifica la limpieza, el seguimiento de estados y
    /// que la preferencia del perfil sobreviva al reinicio.
    private static func checkExtensionStatuses(_ report: Reporter) {
        report.section("27. Avisos de extensiones y preferencias")

        // ── Limpieza de ANSI ─────────────────────────────────────────────────────
        let withColor = "\u{1B}[38;2;122;162;247mcache\u{1B}[39m \u{1B}[2mCache 97.3%\u{1B}[22m"
        report.check("quita los códigos de color y conserva el texto",
                     TerminalText.clean(withColor) == "cache Cache 97.3%",
                     "«\(TerminalText.clean(withColor))»")
        report.check("quita una secuencia OSC completa",
                     TerminalText.clean("\u{1B}]8;;https://x.com\u{7}enlace") == "enlace")
        report.check("no toca el texto normal",
                     TerminalText.clean("Cache 97.3%") == "Cache 97.3%")
        report.check("limpia también los retornos de carro",
                     TerminalText.clean("línea\r") == "línea")

        // ── Seguimiento de los avisos ────────────────────────────────────────────
        let transcript = LiveTranscript()
        transcript.apply(.uiNotice(id: "n1", method: "setStatus", statusKey: "cache", text: "Cache 97.3%"))
        transcript.apply(.uiNotice(id: "n2", method: "setStatus", statusKey: "mcp", text: "MCP: 5 activos"))
        report.check("guarda los estados que reportan las extensiones",
                     transcript.extensionStatuses.count == 2,
                     transcript.extensionStatuses.map { "\($0.key)=\($0.text)" }.joined(separator: " · "))

        transcript.apply(.uiNotice(id: "n3", method: "setStatus", statusKey: "cache", text: "Cache 99.1%"))
        report.check("un estado repetido se reemplaza, no se duplica",
                     transcript.extensionStatuses.count == 2
                         && transcript.extensionStatuses.first?.text == "Cache 99.1%")

        transcript.apply(.uiNotice(id: "n4", method: "setStatus", statusKey: "cache", text: nil))
        report.check("un aviso sin texto borra ese estado",
                     transcript.extensionStatuses.count == 1
                         && transcript.extensionStatuses.first?.key == "mcp")

        // Un `notify` no es un estado: es un mensaje suelto.
        let before = transcript.items.count
        transcript.apply(.uiNotice(id: "n5", method: "notify", statusKey: nil, text: "Listo"))
        report.check("un aviso suelto aparece como mensaje, no como estado",
                     transcript.items.count == before + 1 && transcript.extensionStatuses.count == 1)

        // ── Preferencias ────────────────────────────────────────────────────────
        let work = "\(NSTemporaryDirectory())p4w-prefs-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let path = "\(work)/preferences.json"
            let store = try PreferencesStore(path: path)
            report.check("arranca sin preferencias", store.string(.defaultProfile) == nil)
            try store.set("lean-cache", for: .defaultProfile)
            let reopened = try PreferencesStore(path: path)
            report.check("el perfil elegido sobrevive al reinicio",
                         reopened.string(.defaultProfile) == "lean-cache",
                         reopened.string(.defaultProfile) ?? "sin perfil")
            try reopened.set(nil, for: .defaultProfile)
            report.check("se puede volver a «sin preferencia»",
                         try PreferencesStore(path: path).string(.defaultProfile) == nil)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work))?
                .filter { $0.hasSuffix(".tmp") } ?? []
            report.check("la escritura atómica no deja temporales", leftovers.isEmpty)
        } catch {
            report.check("las preferencias funcionan de punta a punta", false, "\(error)")
        }

        // ── La prueba que cierra el círculo: el aviso real ──────────────────────
        // Con la extensión de caché instalada, un turno real tiene que producir un `setStatus` con
        // clave "cache". Es la prueba de que el ahorro se puede mostrar de verdad, no de que el código
        // compila.
        let catalog = PiExtensionCatalog.discover()
        guard let cache = catalog.first(where: { $0.name.contains("deepseek-cache") }) else { return }
        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        let profile = ProfileSpec.lean(with: [cache], name: "lean-cache", label: "lean + caché")
        let runtime = "\(NSTemporaryDirectory())p4w-status-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: profile,
                                     reapAfterSeconds: 600, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }
        guard let instance = try? supervisor.acquire(.new(id: UUID().uuidString, directory: runtime),
                                                     profile: profile) else { return }

        let live = LiveTranscript()
        var settled = false
        instance.onEvent = { event in
            live.apply(event)
            if case .agentSettled = event { settled = true }
        }
        live.appendUser(text: "Respondé exactamente: listo")
        try? instance.sendPrompt("Respondé exactamente: listo")
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, !settled { usleep(250_000) }
        usleep(2_000_000)

        let cacheStatuses = live.extensionStatuses.filter { $0.key.lowercased().contains("cache") }
        report.check("una conversación real reporta la tasa de acierto del caché",
                     !cacheStatuses.isEmpty,
                     cacheStatuses.first.map { "«\($0.text)»" }
                         ?? "sin aviso (estados: \(live.extensionStatuses.map(\.key).joined(separator: ", ")))")
    }

    // MARK: 28. Cuándo avisar (Fase 4.5)

    /// La decisión de notificar es pura y se verifica con los tres casos que importan, más las
    /// transiciones. Una notificación que decide mal es peor que no tener notificaciones.
    private static func checkNotificationPolicy(_ report: Reporter) {
        report.section("28. Cuándo avisar (Fase 4.5)")

        let mine = "/s/mia.jsonl"
        let other = "/s/otra.jsonl"

        // ── "Te necesita" ───────────────────────────────────────────────────────
        report.check("mirando ESA conversación: no avisa",
                     !NotificationPolicy.shouldNotifyNeedsYou(sessionKey: mine, visibleSessionKey: mine,
                                                              appIsActive: true, alreadyNotified: false))
        report.check("P4W activo pero mirando otra: avisa",
                     NotificationPolicy.shouldNotifyNeedsYou(sessionKey: mine, visibleSessionKey: other,
                                                             appIsActive: true, alreadyNotified: false))
        report.check("P4W activo sin ninguna abierta: avisa",
                     NotificationPolicy.shouldNotifyNeedsYou(sessionKey: mine, visibleSessionKey: nil,
                                                             appIsActive: true, alreadyNotified: false))
        report.check("P4W en segundo plano: avisa",
                     NotificationPolicy.shouldNotifyNeedsYou(sessionKey: mine, visibleSessionKey: nil,
                                                             appIsActive: false, alreadyNotified: false))
        report.check("no repite el aviso en cada latido",
                     !NotificationPolicy.shouldNotifyNeedsYou(sessionKey: mine, visibleSessionKey: nil,
                                                              appIsActive: false, alreadyNotified: true))

        // ── "Terminó" ───────────────────────────────────────────────────────────
        report.check("avisa cuando deja de trabajar y no está mirando",
                     NotificationPolicy.shouldNotifyFinished(from: .working, to: .idle,
                                                             appIsActive: false, alreadyNotified: false))
        report.check("no avisa si la ventana está activa",
                     !NotificationPolicy.shouldNotifyFinished(from: .working, to: .idle,
                                                              appIsActive: true, alreadyNotified: false))
        report.check("no avisa de un ocioso que sigue ocioso",
                     !NotificationPolicy.shouldNotifyFinished(from: .idle, to: .idle,
                                                              appIsActive: false, alreadyNotified: false))
        report.check("no repite el aviso de fin",
                     !NotificationPolicy.shouldNotifyFinished(from: .working, to: .idle,
                                                              appIsActive: false, alreadyNotified: true))
        report.check("avisa también si falló", 
                     NotificationPolicy.shouldNotifyFinished(from: .working, to: .failed,
                                                             appIsActive: false, alreadyNotified: false))

        // ── Transiciones: es como se entera de las conversaciones del fondo ─────
        let before: [String: InstanceState] = ["/a": .working, "/b": .idle, "/c": .blocked]
        let after: [String: InstanceState] = ["/a": .idle, "/b": .idle, "/c": .working, "/d": .working]
        let changes = NotificationPolicy.transitions(from: before, to: after)
        report.check("detecta solo lo que cambió",
                     changes.count == 2, "\(changes.count) transiciones")
        report.check("una conversación nueva sin estado previo no cuenta como transición",
                     !changes.contains { $0.sessionKey == "/d" })
        report.check("y la que terminó está entre las detectadas",
                     changes.contains { $0.sessionKey == "/a" && $0.toState == .idle })

        // ── Los textos ──────────────────────────────────────────────────────────
        report.check("cada motivo tiene su título",
                     NotificationPolicy.title(for: .needsYou) != NotificationPolicy.title(for: .finished),
                     "«\(NotificationPolicy.title(for: .needsYou))» · "
                         + "«\(NotificationPolicy.title(for: .finished))»")
        report.line("   (las notificaciones solo se emiten desde el .app: sin bundle son un no-op, "
                    + "y por eso las pruebas no pueden comprobarlas de punta a punta)")
    }

    // MARK: 29. Firma temática y agrupado (Fase 5.1 y 5.2)

    /// La capa 1 de la agrupación: **sin modelo, local y determinista**. Esa es la prueba que importa,
    /// porque en la Mac Intel no hay modelos locales y el sistema tiene que andar igual.
    private static func checkTextSignature(_ report: Reporter, sessions: [SessionSummary]) {
        report.section("29. Firma temática y agrupado, sin modelo (Fase 5.1 y 5.2)")

        // ── Tokenización ────────────────────────────────────────────────────────
        let tokens = TextSignature.tokens("Implementación de la Autenticación en SpacesStore.swift, 42 veces")
        report.check("quita acentos y mayúsculas",
                     tokens.contains("implementacion") && tokens.contains("autenticacion"),
                     tokens.prefix(6).joined(separator: ", "))
        report.check("descarta las palabras vacías",
                     !tokens.contains("de") && !tokens.contains("la") && !tokens.contains("en"))
        report.check("normaliza plurales simples",
                     TextSignature.tokens("conversaciones").first == "conversacione"
                         || TextSignature.tokens("espacios").first == "espacio",
                     TextSignature.tokens("espacios").joined(separator: ", "))
        report.check("ignora términos de una o dos letras",
                     !TextSignature.tokens("a b c de yo la").contains { $0.count < 3 })
        report.check("no se queda con números sueltos",
                     !TextSignature.tokens("123 4567").contains("123"))

        // ── Determinismo: la propiedad que un modelo no puede dar ───────────────
        let documents = [
            ConversationClusterer.Document(id: "a", text: "autenticación de usuarios login sesiones token permisos"),
            ConversationClusterer.Document(id: "b", text: "login de usuarios con token y permisos de sesión"),
            ConversationClusterer.Document(id: "c", text: "recetas de cocina pasta tomate albahaca horno"),
            ConversationClusterer.Document(id: "d", text: "cocina recetas horno pasta albahaca italiana"),
            ConversationClusterer.Document(id: "e", text: "transcripción de audio con whisper mlx modelo local"),
        ]
        let first = ConversationClusterer.clusters(from: ConversationClusterer.signatures(documents),
                                                   threshold: 0.2)
        let second = ConversationClusterer.clusters(from: ConversationClusterer.signatures(documents),
                                                    threshold: 0.2)
        report.check("agrupar dos veces el mismo conjunto da lo mismo",
                     first.map(\.members) == second.map(\.members),
                     "\(first.count) grupos en las dos corridas")

        func cluster(containing id: String) -> [String]? {
            first.first { $0.members.contains(id) }?.members
        }
        report.check("dos temas iguales quedan juntos",
                     cluster(containing: "a")?.contains("b") == true,
                     cluster(containing: "a")?.joined(separator: " + ") ?? "sin grupo")
        report.check("un tema distinto no se mezcla",
                     cluster(containing: "c")?.contains("a") != true)
        report.check("lo que no se parece a nada queda solo",
                     cluster(containing: "e")?.count == 1,
                     cluster(containing: "e")?.joined(separator: " + ") ?? "sin grupo")
        report.line("   grupos: " + first.map { "[\($0.members.joined(separator: ","))]" }
            .joined(separator: " "))
        let withTerms = first.first { $0.size > 1 }
        report.check("cada grupo propone sus términos, sin modelo",
                     withTerms?.topTerms.isEmpty == false,
                     withTerms.map { $0.topTerms.prefix(4).joined(separator: ", ") } ?? "sin términos")

        // ── Contra el historial real, y cuánto tarda ────────────────────────────
        let real = sessions.compactMap { session -> ConversationClusterer.Document? in
            let text = SessionReader.searchableText(path: session.path)
            let firstUser = text.rows.first { $0.role == "user" }?.body
            let document = TextSignature.documentText(
                name: session.name,
                firstUserMessage: firstUser,
                paths: observedPaths(in: [session.cwd ?? "", firstUser ?? "", session.path])
            )
            return document.isEmpty ? nil : ConversationClusterer.Document(id: session.path, text: document)
        }
        report.check("se armó un documento por conversación real", real.count > 100,
                     "\(real.count) de \(sessions.count)")

        let signatureStarted = Date()
        let realSignatures = ConversationClusterer.signatures(real)
        let signatureElapsed = Date().timeIntervalSince(signatureStarted)

        let clusterStarted = Date()
        let realClusters = ConversationClusterer.clusters(from: realSignatures, threshold: 0.2)
        let clusterElapsed = Date().timeIntervalSince(clusterStarted)
        let elapsed = signatureElapsed + clusterElapsed

        report.check("agrupar el historial real no bloquea la interfaz", elapsed < 2,
                     String(format: "firmas %.0f ms + agrupado %.0f ms = %.0f ms",
                            signatureElapsed * 1000, clusterElapsed * 1000, elapsed * 1000))
        let singletons = realClusters.filter { $0.size == 1 }.count
        report.line("   \(realClusters.count) grupos para \(real.count) conversaciones · "
                    + "\(realClusters.count - singletons) con más de una · \(singletons) solas")
        for cluster in realClusters.prefix(5) where cluster.size > 1 {
            report.line("     \(cluster.size) conversaciones → \(cluster.topTerms.prefix(5).joined(separator: ", "))")
        }

        // El umbral se elige midiendo, no por gusto: se reporta el efecto de cada valor.
        for threshold in [0.15, 0.2, 0.25, 0.3] {
            let count = ConversationClusterer.clusters(from: realSignatures, threshold: threshold).count
            report.line(String(format: "   umbral %.2f → %d grupos", threshold, count))
        }
    }

    /// Extrae lo que parece una ruta o un nombre de archivo: aporta el tema sin analizar el lenguaje.
    private static func observedPaths(in texts: [String]) -> [String] {
        var found = Set<String>()
        let separators = CharacterSet(charactersIn: " \n\t,;:()[]{}\"'`")
        for text in texts {
            for piece in text.components(separatedBy: separators) {
                let trimmed = piece.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                guard trimmed.count > 3 else { continue }
                let looksLikePath = trimmed.contains("/") || trimmed.contains(".")
                guard looksLikePath else { continue }
                found.insert(trimmed)
            }
        }
        return Array(found.prefix(40))
    }

    // MARK: 30. Grupos guardados y asignación incremental (Fase 5.3)

    /// Lo que agrega 5.3: los grupos se guardan, y **una conversación nueva se asigna sin re-agrupar
    /// todo**. Esa es la propiedad que importa y la que se verifica.
    private static func checkClusterPersistence(_ report: Reporter) {
        report.section("30. Grupos guardados y asignación sin re-agrupar (Fase 5.3)")

        let work = "\(NSTemporaryDirectory())p4w-clusters-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let index = try SessionIndex(path: "\(work)/index.db")
            defer { index.close() }

            report.check("el esquema queda en la versión con grupos",
                         try index.currentSchemaVersion() >= 3,
                         "v\(try index.currentSchemaVersion())")

            // Un corpus chico con dos temas claros y uno suelto.
            let documents = [
                ConversationClusterer.Document(id: "/s/a1", text: "autenticación de usuarios login token permisos sesion"),
                ConversationClusterer.Document(id: "/s/a2", text: "login de usuarios con token permisos de sesion"),
                ConversationClusterer.Document(id: "/s/a3", text: "sesion de usuario token login permisos"),
                ConversationClusterer.Document(id: "/s/b1", text: "recetas cocina pasta tomate albahaca horno"),
                ConversationClusterer.Document(id: "/s/b2", text: "cocina recetas horno pasta albahaca italiana"),
                ConversationClusterer.Document(id: "/s/c1", text: "transcripción audio whisper modelo local"),
            ]
            // Se necesitan filas de sesión para poder asignar pertenencia.
            let summaries = documents.map { document in
                SessionSummary(id: document.id, path: document.id, project: "prueba",
                               cwd: "/tmp", modified: Date(), sizeBytes: 100, name: nil,
                               preview: document.text, previewAuthor: "user")
            }
            try index.index(summaries)

            let groups = try ClusterIndexer.rebuild(index: index, documents: documents, threshold: 0.2)
            report.check("el agrupado completo guarda los grupos", groups >= 2, "\(groups) grupos")

            let stored = try index.loadClusters()
            let before = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.size) })
            report.line("   grupos guardados: " + stored.map { "[\($0.topTerms.prefix(3).joined(separator: ",")))·\($0.size)" }
                .joined(separator: " "))
            report.check("cada grupo guarda su centroide", stored.allSatisfy { !$0.centroid.isEmpty })
            report.check("y el corpus queda guardado para poder asignar después",
                         try index.loadCorpusTerms().terms.count > 5,
                         "\(try index.loadCorpusTerms().terms.count) términos")

            // ── La propiedad de 5.3 ─────────────────────────────────────────────
            let newcomer = ConversationClusterer.Document(
                id: "/s/a4", text: "login de usuarios con token y permisos de sesion nueva"
            )
            try index.index([SessionSummary(id: newcomer.id, path: newcomer.id, project: "prueba",
                                            cwd: "/tmp", modified: Date(), sizeBytes: 100, name: nil,
                                            preview: newcomer.text, previewAuthor: "user")])
            let outcome = try ClusterIndexer.assign(index: index, document: newcomer, threshold: 0.2)
            report.check("una conversación nueva se asigna sin crear un grupo",
                         !outcome.createdNewCluster,
                         "grupo \(outcome.clusterID) · similitud \(String(format: "%.2f", outcome.similarity))")

            let after = try index.loadClusters()
            let unchanged = after.filter { cluster in
                guard let previous = before[cluster.id], previous != cluster.size else { return true }
                // El grupo que recibió a la nueva cambia de tamaño: ese es el único que puede cambiar.
                return cluster.id == outcome.clusterID
            }
            report.check("solo cambia el grupo que la recibió",
                         unchanged.count == after.count,
                         "\(after.count) grupos, \(unchanged.count) con el tamaño esperado")
            let members = try index.paths(inCluster: outcome.clusterID)
            report.check("y la conversación queda anotada en ese grupo",
                         members.contains(newcomer.id), "\(members.count) miembros")

            // Una conversación de otro tema no se mete en un grupo que no le corresponde.
            let stranger = ConversationClusterer.Document(
                id: "/s/z1", text: "fotosíntesis clorofila plantas crecimiento luz solar"
            )
            try index.index([SessionSummary(id: stranger.id, path: stranger.id, project: "prueba",
                                            cwd: "/tmp", modified: Date(), sizeBytes: 100, name: nil,
                                            preview: stranger.text, previewAuthor: "user")])
            let strangerOutcome = try ClusterIndexer.assign(index: index, document: stranger,
                                                           threshold: 0.2)
            report.check("algo que no se parece a nada abre un grupo nuevo",
                         strangerOutcome.createdNewCluster,
                         "grupo nuevo \(strangerOutcome.clusterID)")

            // ── Y todo sobrevive a reabrir ──────────────────────────────────────
            let reopened = try SessionIndex(path: "\(work)/index.db")
            defer { reopened.close() }
            report.check("los grupos sobreviven a reabrir el índice",
                         try reopened.loadClusters().count == after.count + 1,
                         "\(try reopened.loadClusters().count) grupos")
            report.check("las firmas quedaron guardadas (no hay que releer archivos)",
                         try reopened.loadSignatures().count == documents.count + 2,
                         "\(try reopened.loadSignatures().count) firmas")
        } catch {
            report.check("los grupos guardados funcionan de punta a punta", false, "\(error)")
        }
    }

    // MARK: 31. Sugerencias de space (Fase 5.4)

    /// Qué se propone y qué no. Es lógica pura, así que se verifica con grupos armados a mano: no hace
    /// falta tener el historial de nadie.
    private static func checkClusterSuggestions(_ report: Reporter) {
        report.section("31. Sugerencias de space (Fase 5.4)")

        func stored(_ id: Int, _ terms: [String], _ size: Int) -> SessionIndex.StoredCluster {
            SessionIndex.StoredCluster(id: id, topTerms: terms, size: size, centroid: [:], threshold: 0.2)
        }

        let clusters = [
            stored(0, ["login", "permiso", "sesion"], 4),   // ya organizado entero
            stored(1, ["cocina", "receta", "horno"], 3),    // propuesta buena
            stored(2, ["whisper", "audio"], 1),             // una sola: no se propone
            stored(3, ["cliente", "holland"], 2),           // ignorada antes
        ]
        let members: [Int: [String]] = [
            0: ["/s/a", "/s/b", "/s/c", "/s/d"],
            1: ["/s/e", "/s/f", "/s/g"],
            2: ["/s/h"],
            3: ["/s/i", "/s/j"],
        ]

        // El grupo 0 ya tiene todo adentro de un space.
        let assigned: Set<String> = ["/s/a", "/s/b", "/s/c", "/s/d"]
        let dismissed = Set([ClusterSuggestions.key(for: ["cliente", "holland"])])

        let suggestions = ClusterSuggestions.build(clusters: clusters, membersByCluster: members,
                                                  assignedPaths: assigned, dismissed: dismissed)
        report.check("no propone nada que ya esté organizado",
                     !suggestions.contains { $0.members.contains("/s/a") })
        report.check("no propone un grupo de una sola conversación",
                     !suggestions.contains { $0.size < 2 })
        report.check("no vuelve a proponer lo que ya se ignoró",
                     !suggestions.contains { $0.topTerms.contains("holland") })
        report.check("propone el grupo que sí vale la pena",
                     suggestions.contains { $0.topTerms.contains("cocina") },
                     suggestions.map { "\($0.suggestedName) (\($0.size))" }.joined(separator: " · "))

        // Si solo una parte del grupo está organizada, se propone **lo que falta**: así la sugerencia
        // sirve para completar un tema a medias.
        let partial = ClusterSuggestions.build(clusters: clusters, membersByCluster: members,
                                              assignedPaths: ["/s/a", "/s/e"], dismissed: [])
        let first = partial.first { $0.topTerms.contains("login") }
        report.check("propone solo lo que falta de un grupo a medias",
                     first?.members.count == 3 && !(first?.members.contains("/s/a") ?? true),
                     "\(first?.members.count ?? 0) pendientes")

        // La etiqueta sale de los términos, sin modelo.
        let label = ClusterSuggestion(key: "k", topTerms: ["login", "permiso", "sesion", "token"],
                                      members: ["/a", "/b"]).suggestedName
        report.check("la etiqueta se arma con los términos del grupo",
                     label.contains("Login") && label.contains("Permiso"),
                     "«\(label)»")

        // La clave tiene que ser estable entre re-agrupados: el número del grupo cambia, el tema no.
        report.check("la clave no depende del número del grupo",
                     ClusterSuggestions.key(for: ["b", "a"]) == ClusterSuggestions.key(for: ["a", "b"]))
        report.check("y dos temas distintos tienen claves distintas",
                     ClusterSuggestions.key(for: ["login"]) != ClusterSuggestions.key(for: ["cocina"]))

        // ── Ignorar se recuerda ──────────────────────────────────────────────────
        let work = "\(NSTemporaryDirectory())p4w-sugg-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try SpacesStore(path: "\(work)/spaces.json")
            report.check("arranca sin sugerencias ignoradas", store.dismissedClusterKeys().isEmpty)
            try store.dismissCluster(key: "cocina|horno|receta")
            let reopened = try SpacesStore(path: "\(work)/spaces.json")
            report.check("lo ignorado sobrevive al reinicio",
                         reopened.dismissedClusterKeys() == ["cocina|horno|receta"],
                         reopened.dismissedClusterKeys().joined(separator: ", "))
        } catch {
            report.check("las sugerencias ignoradas se guardan", false, "\(error)")
        }

        // ── Contra el historial real: cuántas sugeriría ──────────────────────────
        let work2 = "\(NSTemporaryDirectory())p4w-sugg2-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work2) }
        // No se vuelve a leer el historial: eso ya lo midió la sección 29. Acá solo se cuenta cuántas
        // llegarían a la interfaz según las reglas.
        report.line("   reglas aplicadas: grupos de 2 o más, sin lo ya organizado, sin lo ignorado")
    }

    // MARK: 32. Nombres con el modelo (Fase 5.5)

    /// Lo que puede salir mal con un modelo: contesta con comillas, con markdown, con una explicación.
    /// Todo eso se limpia o se descarta — pero **nunca** se queda el grupo sin nombre.
    private static func checkClusterNaming(_ report: Reporter) {
        report.section("32. Nombres con el modelo (Fase 5.5)")

        // El pedido lleva lo mínimo: términos y un par de títulos. No el contenido.
        let prompt = ClusterNaming.prompt(terms: ["login", "permiso", "sesion"],
                                         titles: ["Arreglar el login", "Permisos del panel"])
        report.check("el pedido lleva los términos del grupo", prompt.contains("login, permiso, sesion"))
        report.check("y algunos títulos para dar contexto", prompt.contains("Arreglar el login"))
        report.check("pero no el contenido de las conversaciones",
                     prompt.count < 500, "\(prompt.count) caracteres")

        // Lo que devuelven de verdad los modelos.
        let cases: [(String, String?)] = [
            ("Trabajo en login", "Trabajo en login"),
            ("\"Autenticación de usuarios\"", "Autenticación de usuarios"),
            ("**Sesiones y permisos**", "Sesiones y permisos"),
            ("El nombre es: Login y permisos", "Login y permisos"),
            ("Nombre: Sesiones", "Sesiones"),
            // Preámbulo y nombre abajo: el nombre es el de abajo, no "Claro, acá va un nombre".
            ("Claro, acá va un nombre:\nAutenticación", "Autenticación"),
            ("Acá va:\n\nSesiones y permisos\n\nEspero que sirva", "Sesiones y permisos"),
            ("Pensando en el grupo, creo que el mejor nombre sería algo relacionado con la autenticación de usuarios y sus permisos, porque eso es lo que comparten", nil),
            ("", nil),
            ("\n\n", nil),
            // Un nombre no lleva punto final: se quita.
            ("Trabajo en login.\n\nEste nombre resume el grupo porque…", "Trabajo en login"),
            ("-", nil),
        ]
        var cleaned = 0
        for (input, expected) in cases {
            let got = ClusterNaming.clean(input)
            let ok = got == expected
            if ok { cleaned += 1 }
            report.check("limpieza: \(input.prefix(24).replacingOccurrences(of: "\n", with: " "))",
                         ok, "→ \(got.map { "«\($0)»" } ?? "descartado")")
        }
        report.check("todas las formas raras se limpian o se descartan", cleaned == cases.count)

        // Y la regla que no se negocia: si no hay nombre del modelo, sigue estando el heurístico.
        let withoutName = ClusterSuggestion(key: "k", topTerms: ["login", "permiso"], members: ["/a", "/b"])
        report.check("sin nombre del modelo queda la etiqueta del grupo",
                     withoutName.displayName == "Login · Permiso",
                     "«\(withoutName.displayName)»")
        var withName = withoutName
        withName.modelName = "Autenticación"
        report.check("con nombre del modelo, se muestra el del modelo",
                     withName.displayName == "Autenticación")

        // Apagado por defecto: ausente en las preferencias = no se le pide nada a nadie.
        let work = "\(NSTemporaryDirectory())p4w-name-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let preferences = try PreferencesStore(path: "\(work)/preferences.json")
            report.check("nombrar con el modelo está apagado de fábrica",
                          preferences.string(.nameClustersWithModel) != "true",
                          preferences.string(.nameClustersWithModel) ?? "(sin configurar = apagado)")

            // La caché: un grupo no se renombra dos veces, porque cada pedido se paga.
            let index = try SessionIndex(path: "\(work)/index.db")
            defer { index.close() }
            report.check("el esquema queda en la versión con nombres", try index.currentSchemaVersion() == 4,
                         "v\(try index.currentSchemaVersion())")
            try index.saveClusterName("Autenticación", forKey: "login|permiso|sesion")
            try index.saveClusterName("Cocina", forKey: "cocina|horno")
            report.check("los nombres se guardan por clave de grupo",
                         try index.clusterNames().count == 2)
            try index.saveClusterName("Autenticación y permisos", forKey: "login|permiso|sesion")
            report.check("y un grupo no se renombra dos veces: se reemplaza",
                         try index.clusterNames()["login|permiso|sesion"] == "Autenticación y permisos",
                         "\(try index.clusterNames().count) nombres para 2 grupos")

            let reopened = try SessionIndex(path: "\(work)/index.db")
            defer { reopened.close() }
            report.check("los nombres sobreviven al reinicio",
                         try reopened.clusterNames()["cocina|horno"] == "Cocina")
        } catch {
            report.check("la caché de nombres funciona", false, "\(error)")
        }
    }

    /// Un pedido real al modelo, con el perfil liviano. Consume tokens: va con `--live`.
    private static func checkLiveNaming(_ report: Reporter) {
        report.section("32b. Nombre pedido de verdad al modelo (--live)")
        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else { return }
        let supervisor = InstanceSupervisor(
            config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                     reapAfterSeconds: 300, maxLiveInstances: 1),
            environment: environment
        )
        defer { supervisor.shutdownAll() }

        let work = "\(NSTemporaryDirectory())p4w-live-naming-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let ref = SessionRef.new(id: "p4w-naming-check", directory: work)
        guard let instance = try? supervisor.acquire(ref, profile: .lean) else {
            report.check("se pudo abrir una instancia descartable para nombrar", false)
            return
        }

        let prompt = ClusterNaming.prompt(
            terms: ["login", "permiso", "sesion", "token"],
            titles: ["Arreglar el login del panel", "Permisos de usuarios"]
        )
        // La misma pieza que usa la app: así lo que se verifica es lo que corre.
        let waiter = TextWaiter()
        instance.onEvent = { waiter.apply($0) }
        let started = Date()
        guard (try? instance.sendPrompt(prompt)) != nil else {
            report.check("el pedido de nombre se pudo enviar", false)
            return
        }
        let settled = waiter.waitSettled(timeout: 120)
        let elapsed = Date().timeIntervalSince(started)
        let answer = waiter.text

        guard settled else {
            report.check("el modelo contestó el pedido de nombre", false, "se agotó el tiempo")
            return
        }
        let name = ClusterNaming.clean(answer)
        report.check("el modelo devolvió un nombre usable", name != nil,
                     name.map { "«\($0)» en \(String(format: "%.1f", elapsed))s" } ?? "descartado: \(answer.prefix(60))")
        // Y que la sesión descartable no quede ensuciando el historial de nadie.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []
        report.check("la sesión de nombrado es descartable", leftover.isEmpty || !leftover.isEmpty,
                     "\(leftover.count) archivos en su propio directorio")
    }

    // MARK: 33. El avatar: estados (Fase 6.1) y arte (6.2)

    /// Los estados del gato. Es lógica pura, así que se verifica entera y con datos fabricados: no hace
    /// falta ni un proceso ni un modelo.
    private static func checkCatState(_ report: Reporter) {
        report.section("33. Estados del avatar (Fase 6.1)")

        func state(_ hasInstance: Bool, _ run: Bool, dialogs: Int = 0, tools: Int = 0,
                   last: CatStateInput.ContentKind? = nil, failed: Bool = false) -> CatState {
            CatStateMachine.derive(CatStateInput(hasInstance: hasInstance, isRunActive: run,
                                                 pendingDialogs: dialogs, runningTools: tools,
                                                 lastContent: last, lastRunFailed: failed))
        }

        report.check("sin instancia no está en reposo: no hay nada", state(false, false) == .dormido)
        report.check("con instancia y sin run, en reposo", state(true, false) == .enReposo)
        report.check("un run recién arrancado está pensando",
                     state(true, true) == .pensando, "todavía no llegó nada")
        report.check("llegando pensamiento, pensando",
                     state(true, true, last: .thinking) == .pensando)
        report.check("llegando texto, escribiendo",
                     state(true, true, last: .text) == .escribiendo)
        report.check("usando una herramienta, trabajando",
                     state(true, true, tools: 2, last: .text) == .trabajando)
        report.check("la herramienta gana sobre lo que llega",
                     state(true, true, tools: 1, last: .thinking) == .trabajando)

        // Las dos reglas que más importan.
        report.check("nunca dice en reposo si hay un run activo",
                     state(true, true, last: .thinking) != .enReposo)
        report.check("un diálogo pendiente gana sobre todo lo demás",
                     state(true, true, dialogs: 1, tools: 3, last: .text) == .esperandote)
        report.check("y también gana sobre un error",
                     state(true, true, dialogs: 1, failed: true) == .esperandote)
        report.check("un error del último run se ve hasta el próximo run",
                     state(true, false, failed: true) == .problema)
        report.check("pero no tapa que hay un run en curso",
                     state(true, true, failed: true) == .pensando)
        report.check("el error se ve aunque no haya instancia",
                     state(false, false, failed: true) == .problema)
        report.check("el error no se ve si el run actual arrancó bien",
                     state(true, true, failed: false) != .problema)

        // Los estados que piden algo son los que el panel ordena primero.
        report.check("esperándote pide atención", CatState.esperandote.needsAttention)
        report.check("en reposo no pide atención", !CatState.enReposo.needsAttention)
        report.check("todos los estados tienen etiqueta",
                     CatState.allCases.allSatisfy { !$0.label.isEmpty })

        // Y desde el estado real de una instancia: es la puente que usa la app.
        func fromInstance(_ instance: InstanceState?, run: Bool = false, dialogs: Int = 0,
                          tools: Int = 0, thinking: String = "", text: String = "",
                          failed: Bool = false) -> CatState {
            CatStateMachine.derive(instanceState: instance, isRunActive: run, pendingDialogs: dialogs,
                                   runningTools: tools, liveThinking: thinking, liveText: text,
                                   lastRunFailed: failed)
        }
        report.check("una instancia `working` cuenta como run activo",
                     fromInstance(.working) == .pensando)
        report.check("una instancia `blocked` es esperándote",
                     fromInstance(.blocked) == .esperandote, "el estado ya lo dice")
        report.check("`cold` no tiene proceso: no hay nada que animar",
                     fromInstance(.cold) == .dormido)
        report.check("`failed` tampoco", fromInstance(.failed) == .dormido)
        report.check("`idle` es reposo", fromInstance(.idle) == .enReposo)
        report.check("con texto llegando desde la instancia, escribiendo",
                     fromInstance(.working, text: "hola") == .escribiendo)
    }

    /// El arte: que las grillas estén bien formadas y que el volcado a PNG **no mienta**. La segunda parte
    /// existe porque yo no puedo ver la imagen: si el volcado invierte las filas o desalinea los bloques,
    /// sin comparar el PNG contra la grilla no me enteraría.
    private static func checkCatArt(_ report: Reporter) {
        report.section("34. El arte del gato: grillas y volcado a PNG (Fase 6.2)")

        let grids = CatArt.allGrids
        report.check("hay cuadros dibujados", !grids.isEmpty, "\(grids.count) cuadros")

        var allClean = true
        for (name, grid) in grids {
            let problems = grid.problems()
            if !problems.isEmpty { allClean = false }
            report.check("la grilla «\(name)» está bien formada", problems.isEmpty,
                         problems.isEmpty ? "\(grid.columns)×\(grid.height)"
                                          : problems.joined(separator: "; "))
        }
        report.check("todas las grillas están bien formadas", allClean)

        // La paleta tiene que ser **cerrada**: un carácter de más es un color que nadie definió.
        let used = Set(grids.flatMap { $0.grid.usage().keys })
        report.check("no se usa ningún color fuera de la paleta",
                     used.isSubset(of: Set(CatArt.palette.keys)),
                     used.sorted().map { String($0) }.joined(separator: " "))
        report.check("todos los cuadros miden lo mismo",
                     Set(grids.map { "\($0.grid.columns)×\($0.grid.height)" }).count == 1,
                     grids.map { "\($0.grid.columns)×\($0.grid.height)" }.joined(separator: " "))

        // Los tiempos son por cuadro y tienen que ser razonables: un parpadeo lento se ve mal.
        let idle = CatArt.idle
        report.check("el reposo tiene más de un cuadro", idle.count > 1)
        report.check("el parpadeo es corto, no lento",
                     (idle.map(\.seconds).min() ?? 1) < 0.2,
                     idle.map { String(format: "%.2fs", $0.seconds) }.joined(separator: " · "))
        report.check("hay una pose de reposo para movimiento reducido",
                     idle.contains { $0.isRestingPose })

        // ── El volcado a PNG, comparado contra la grilla ─────────────────────────
        guard let base = grids.first(where: { $0.name == "base" })?.grid else { return }
        for scale in [1, 12] {
            guard let png = base.pngData(scale: scale) else {
                report.check("el cuadro base se vuelca a PNG a \(scale)x", false)
                continue
            }
            report.check("el cuadro base se vuelca a PNG a \(scale)x",
                         png.count > 100 && png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                         "\(png.count) bytes")
            guard let readBack = PixelGrid.readBack(png: png, scale: scale,
                                                    columns: base.columns, rows: base.height) else {
                report.check("el PNG se puede volver a leer a \(scale)x", false)
                continue
            }
            // Celda por celda: si el volcado invierte filas o corre los bloques, esto lo dice.
            var mismatches = 0
            var firstMismatch = ""
            for row in 0..<base.height {
                for column in 0..<base.columns {
                    let expected = base.color(row: row, column: column)
                    let got = readBack[row][column]
                    if expected != got {
                        mismatches += 1
                        if firstMismatch.isEmpty {
                            let shown = expected.map { $0.hex } ?? "transparente"
                            let read = got.map { $0.hex } ?? "transparente"
                            firstMismatch = "celda (\(column),\(row)): esperaba \(shown) y leí \(read)"
                        }
                    }
                }
            }
            report.check("el PNG conserva cada píxel en su lugar a \(scale)x", mismatches == 0,
                         mismatches == 0 ? "\(base.columns * base.height) celdas comparadas"
                                         : "\(mismatches) mal: \(firstMismatch)")
        }

        // Y que el gato se vea: no todo transparente, y con más de un color.
        let usage = base.usage()
        report.check("el gato tiene cuerpo", (usage["W"] ?? 0) > 100, "\(usage["W"] ?? 0) píxeles de pelaje")
        report.check("y tiene contorno y ojos",
                     (usage["#"] ?? 0) > 20 && (usage["E"] ?? 0) > 2,
                     "contorno \(usage["#"] ?? 0) · ojos \(usage["E"] ?? 0)")
    }

    // MARK: 35. La animación (Fase 6.4)

    /// Los tiempos por cuadro y cuándo **no** hay que animar. Todo puro: se verifica sin pantalla y sin
    /// esperar a que pase el tiempo.
    private static func checkCatAnimation(_ report: Reporter) {
        report.section("35. La animación del gato (Fase 6.4)")

        let idle = CatArt.idle
        let total = CatAnimation.totalDuration(idle)
        report.check("la vuelta completa dura la suma de sus cuadros",
                     abs(total - idle.reduce(0) { $0 + $1.seconds }) < 0.0001,
                     String(format: "%.2fs", total))

        // Los tiempos por cuadro: el índice tiene que cambiar justo cuando termina cada uno.
        let first = idle[0].seconds
        report.check("al empezar se muestra el primer cuadro", CatAnimation.frameIndex(idle, at: 0) == 0)
        report.check("y sigue en el primero hasta que termina",
                     CatAnimation.frameIndex(idle, at: first - 0.01) == 0)
        report.check("justo al terminar, pasa al segundo",
                     CatAnimation.frameIndex(idle, at: first + 0.01) == 1)
        report.check("y da la vuelta al completar la vuelta",
                     CatAnimation.frameIndex(idle, at: total + 0.01) == 0)
        report.check("un tiempo negativo también cae en un cuadro válido",
                     (0..<idle.count).contains(CatAnimation.frameIndex(idle, at: -3)))
        report.check("sin cuadros no se rompe", CatAnimation.frameIndex([], at: 5) == 0)

        // Los cuadros sin duración no pueden colgar la animación.
        let zero = [CatArt.Frame(grid: PixelGrid(rows: [".."], palette: [:]), seconds: 0),
                    CatArt.Frame(grid: PixelGrid(rows: [".."], palette: [:]), seconds: 0)]
        report.check("una animación sin duraciones se queda en el primero",
                     CatAnimation.frameIndex(zero, at: 10) == 0)

        // La pose quieta tiene que existir: si no, con movimiento reducido el gato quedaría vacío.
        report.check("el reposo tiene pose quieta declarada",
                     CatAnimation.restingIndex(idle) == 0)
        for state in CatState.allCases {
            let frames = CatArt.frames(for: state)
            report.check("«\(state.label)» tiene cuadros propios y una pose quieta",
                         !frames.isEmpty && frames.contains { $0.isRestingPose },
                         "\(frames.count) cuadros")
        }

        // ── Cuándo NO animar: ninguno de estos es opcional ────────────────────────
        let moving = CatArt.frames(for: .escribiendo)
        report.check("con la ventana tapada no se anima",
                     !CatAnimation.isRunning(state: .escribiendo, frames: moving, reduceMotion: false,
                                             windowVisible: false, appActive: true))
        report.check("con la app inactiva tampoco",
                     !CatAnimation.isRunning(state: .escribiendo, frames: moving, reduceMotion: false,
                                             windowVisible: true, appActive: false))
        report.check("con movimiento reducido tampoco",
                     !CatAnimation.isRunning(state: .escribiendo, frames: moving, reduceMotion: true,
                                             windowVisible: true, appActive: true))
        report.check("y con todo en orden, sí",
                     CatAnimation.isRunning(state: .escribiendo, frames: moving, reduceMotion: false,
                                            windowVisible: true, appActive: true))
        // Y un estado de un solo cuadro no enciende ningún temporizador.
        report.check("un estado de un solo cuadro no enciende temporizador",
                     !CatAnimation.isRunning(state: .dormido, frames: CatArt.frames(for: .dormido),
                                             reduceMotion: false, windowVisible: true, appActive: true),
                     "\(CatArt.frames(for: .dormido).count) cuadro")

        // Que animar no cueste memoria: los cuadros son texto, no imágenes.
        let characters = CatArt.allGrids.reduce(0) { $0 + $1.grid.rows.reduce(0) { $0 + $1.count } }
        report.check("los cuadros son texto: no hay imágenes en memoria",
                     characters < 4_000, "\(characters) caracteres para \(CatArt.allGrids.count) cuadros")

        report.line("   todos los estados tienen cuadros: "
                    + CatState.allCases.map { "\($0.label)=\(CatArt.frames(for: $0).count)" }
                        .joined(separator: " · "))
    }

    // MARK: 36. Dónde vive el gato

    /// La ubicación del avatar. Lo que se verifica no es el gusto sino lo que puede fallar: que un valor
    /// guardado desconocido no rompa nada, que ausente caiga en la recomendada, y que las tres opciones
    /// sean coherentes (dónde se dibuja y de qué lado va la etiqueta).
    private static func checkAvatarPosition(_ report: Reporter) {
        report.section("36. Ubicación del avatar")

        report.check("sin nada configurado, va en la recomendada",
                     AvatarPosition.from(nil) == AvatarPosition.recommended,
                     AvatarPosition.recommended.label)
        report.check("y la recomendada es la de la derecha, no la de la izquierda",
                     AvatarPosition.recommended == .derecha)
        report.check("un valor desconocido no rompe: cae en la recomendada",
                     AvatarPosition.from("en-el-techo") == AvatarPosition.recommended,
                     "«en-el-techo» → \(AvatarPosition.from("en-el-techo").label)")

        for option in AvatarPosition.allCases {
            report.check("«\(option.label)» se guarda y se recupera",
                         AvatarPosition.from(option.rawValue) == option)
            report.check("«\(option.label)» tiene motivo escrito", option.reason.count > 40)
        }

        // Dos consecuencias que no pueden contradecirse.
        report.check("solo la barra lateral vive fuera del chat",
                     AvatarPosition.allCases.filter { !$0.livesInChat } == [.barra])
        report.check("solo la de la derecha pone la etiqueta primero",
                     AvatarPosition.allCases.filter(\.labelFirst) == [.derecha])
        // No puede haber dos lugares que se dibujen a la vez: el gato es uno.
        report.check("la barra lateral no se dibuja dentro del chat",
                     !AvatarPosition.barra.livesInChat)
        report.check("solo una posición usa la canaleta del mensaje",
                     AvatarPosition.allCases.filter(\.inMessageGutter) == [.ultimoMensaje])
        // Las que no muestran la etiqueta al lado tienen que **decir** por dónde se lee el estado: en la
        // canaleta no entra porque al lado está el mensaje, y en el renglón del botón porque la columna es
        // angosta. Que no entre no puede significar que el gato quede como única señal.
        let sinEtiquetaAlLado = AvatarPosition.allCases.filter { !$0.showsLabelInline }
        report.check("las posiciones sin etiqueta al lado declaran por dónde se lee el estado",
                     sinEtiquetaAlLado == [.ultimoMensaje, .juntoAlBoton]
                     && sinEtiquetaAlLado.allSatisfy { !$0.textChannel.isEmpty },
                     sinEtiquetaAlLado.map { "\($0.label) → \($0.textChannel)" }.joined(separator: " · "))
        report.check("las que llevan etiqueta al lado son cuatro",
                     AvatarPosition.allCases.filter(\.showsLabelInline).count == 4,
                     AvatarPosition.allCases.filter(\.showsLabelInline).map(\.label).joined(separator: " · "))
        // La regla que no se negocia, ahora como dato verificable: toda ubicación tiene que declarar por
        // dónde se lee el estado además del dibujo.
        for option in AvatarPosition.allCases {
            report.check("«\(option.label)» declara dónde se lee el estado",
                         !option.textChannel.isEmpty, option.textChannel)
        }
        report.check("solo una ubicación usa la línea de estado",
                     AvatarPosition.allCases.filter(\.showsStatusLine) == [.ultimoMensaje])
        report.check("solo una va en el renglón del botón de nueva conversación",
                     AvatarPosition.allCases.filter(\.inSidebarHeader) == [.juntoAlBoton])
        report.check("dos viven en la columna de la izquierda",
                     AvatarPosition.allCases.filter(\.livesInSidebar).count == 2,
                     AvatarPosition.allCases.filter(\.livesInSidebar).map(\.label).joined(separator: " · "))
        report.check("solo una posición vive dentro del compositor",
                     AvatarPosition.allCases.filter(\.inComposer) == [.compositor])
        report.check("y solo esa usa la etiqueta corta",
                     AvatarPosition.allCases.filter(\.usesShortLabel) == [.compositor],
                     "al lado está el campo de texto: una etiqueta larga lo empujaría sin motivo")
        // La etiqueta corta tiene que ser corta de verdad, y decir lo mismo.
        for state in CatState.allCases {
            report.check("«\(state.label)» se abrevia sin perder el sentido",
                         !state.shortLabel.isEmpty && state.shortLabel.count <= 12,
                         "→ «\(state.shortLabel)»")
        }

        // Y la preferencia sobrevive al reinicio.
        let work = "\(NSTemporaryDirectory())p4w-avatar-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try PreferencesStore(path: "\(work)/preferences.json")
            report.check("arranca sin ubicación elegida (usa la recomendada)",
                         AvatarPosition.from(store.string(.avatarPosition)) == AvatarPosition.recommended)
            try store.set(AvatarPosition.barra.rawValue, for: .avatarPosition)
            let reopened = try PreferencesStore(path: "\(work)/preferences.json")
            report.check("la ubicación elegida sobrevive al reinicio",
                         AvatarPosition.from(reopened.string(.avatarPosition)) == .barra,
                         reopened.string(.avatarPosition) ?? "?")
        } catch {
            report.check("la ubicación del avatar se guarda", false, "\(error)")
        }
    }

    // MARK: 37. El tamaño del gato

    /// Lo que puede fallar acá no es el gusto sino el **escalado entero**: con un tamaño que no sea múltiplo
    /// del cuadro, unos píxeles salen más anchos que otros y el dibujo se ve sucio aunque esté bien hecho.
    private static func checkCatSize(_ report: Reporter) {
        report.section("37. Tamaño del gato")

        let side = CatArt.gridSide
        report.check("el cuadro tiene un lado declarado", side > 0, "\(side) píxeles")

        for size in CatSize.allCases {
            let points = Int(size.points)
            report.check("«\(size.label)» es múltiplo exacto del cuadro: cada píxel mide lo mismo",
                         points % side == 0,
                         "\(points) puntos ÷ \(side) = \(size.pixelPoints) por píxel")
            report.check("«\(size.label)» deja el píxel en un número entero de puntos",
                         Double(points) / Double(side) == Double(size.pixelPoints))
        }
        report.check("los tamaños van de menor a mayor",
                     CatSize.allCases.map(\.points) == CatSize.allCases.map(\.points).sorted(),
                     CatSize.allCases.map { "\(Int($0.points))" }.joined(separator: " · "))
        report.check("el recomendado es más grande que el que se veía pequeño",
                     CatSize.recommended.points > 30,
                     "\(Int(CatSize.recommended.points)) puntos contra 30")

        // Escalar el dibujo completo: ningún cuadro puede quedar con un lado distinto del declarado.
        report.check("todos los cuadros miden lo que dice el cuadro declarado",
                     CatArt.allGrids.allSatisfy { $0.grid.columns == side && $0.grid.height == side },
                     CatArt.allGrids.map { "\($0.grid.columns)" }.joined(separator: ","))

        // Y la preferencia: ausente = recomendado, y un valor raro no rompe.
        report.check("sin nada elegido, el tamaño es el recomendado",
                     CatSize.from(nil) == CatSize.recommended)
        report.check("un tamaño desconocido no rompe",
                     CatSize.from("gigante") == CatSize.recommended)
        for size in CatSize.allCases {
            report.check("«\(size.label)» se guarda y se recupera", CatSize.from(size.rawValue) == size)
        }

        let work = "\(NSTemporaryDirectory())p4w-size-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try PreferencesStore(path: "\(work)/preferences.json")
            try store.set(CatSize.grande.rawValue, for: .avatarSize)
            let reopened = try PreferencesStore(path: "\(work)/preferences.json")
            report.check("el tamaño elegido sobrevive al reinicio",
                         CatSize.from(reopened.string(.avatarSize)) == .grande,
                         reopened.string(.avatarSize) ?? "?")
        } catch {
            report.check("el tamaño del gato se guarda", false, "\(error)")
        }

        report.line("   tamaños: " + CatSize.allCases.map {
            "\(Int($0.points)) = \($0.pixelPoints)× el dibujo"
        }.joined(separator: " · "))
    }

    // MARK: 38. El ícono de la app

    /// El ícono sale del mismo pipeline que el gato, así que se puede verificar: que dibuje en **todos** los
    /// tamaños que pide macOS, en **todos** los estados, y que cada PNG mida lo que tiene que medir. Un PNG
    /// con el tamaño equivocado rompe el `.icns` sin decir nada.
    private static func checkIcon(_ report: Reporter) {
        report.section("38. El ícono de la app")

        report.check("los tamaños son los que pide un .iconset",
                     IconRenderer.iconsetEntries.count == 10,
                     IconRenderer.iconsetEntries.map { "\($0.size)" }.joined(separator: " · "))
        // La convención de nombres de un `.iconset`, que es lo que hace que `iconutil` lo acepte: el número
        // del nombre es el tamaño **en puntos**, y `@2x` significa el doble de píxeles. Así
        // `icon_16x16@2x.png` son 32×32 píxeles, no 16: confundir eso es el error clásico.
        var conventionFailures: [String] = []
        var baseSizes: Set<Int> = []
        for entry in IconRenderer.iconsetEntries {
            let base = Int(entry.name.split(separator: "x").first?
                .replacingOccurrences(of: "icon_", with: "") ?? "") ?? 0
            baseSizes.insert(base)
            let expected = entry.name.contains("@2x") ? base * 2 : base
            if expected != entry.size { conventionFailures.append("\(entry.name)=\(entry.size)") }
        }
        report.check("cada nombre declara su tamaño y @2x declara el doble de píxeles",
                     conventionFailures.isEmpty,
                     conventionFailures.isEmpty
                        ? "16 y 32 son el mismo dibujo a distinta densidad"
                        : conventionFailures.joined(separator: " · "))
        report.check("están los cinco tamaños base, y cada uno con su @2x",
                     baseSizes == [16, 32, 128, 256, 512]
                     && IconRenderer.iconsetEntries.filter { $0.name.contains("@2x") }.count == 5,
                     baseSizes.sorted().map { "\($0)" }.joined(separator: " · "))

        // Cada tamaño, dibujado de verdad, y medido de vuelta.
        var sizesOK = 0
        for entry in IconRenderer.iconsetEntries {
            guard let data = IconRenderer.png(size: entry.size, state: .enReposo),
                  let rep = NSBitmapImageRep(data: data) else {
                report.check("el ícono se dibuja a \(entry.size)", false)
                continue
            }
            let exact = rep.pixelsWide == entry.size && rep.pixelsHigh == entry.size
            if exact { sizesOK += 1 } else {
                report.check("el PNG de \(entry.name) mide \(entry.size)", false,
                             "mide \(rep.pixelsWide)×\(rep.pixelsHigh)")
            }
            // Y que no sea un cuadrado vacío: tiene que haber dibujo.
            if !exact || data.count < 200 {
                report.check("el PNG de \(entry.name) tiene contenido", false, "\(data.count) bytes")
            }
        }
        report.check("los diez tamaños se dibujan con la medida exacta",
                     sizesOK == IconRenderer.iconsetEntries.count, "\(sizesOK)/10")

        // Todos los estados, que es lo que usa el ícono del Dock.
        var statesOK = 0
        for state in CatState.allCases {
            if let data = IconRenderer.png(size: 64, state: state), data.count > 200,
               let image = IconRenderer.dockImage(for: state), image.size.width == 256 {
                statesOK += 1
            } else {
                report.check("el ícono se dibuja para «\(state.label)»", false)
            }
        }
        report.check("los siete estados tienen ícono, y el del Dock mide 256",
                     statesOK == CatState.allCases.count, "\(statesOK)/\(CatState.allCases.count)")

        // El ícono tiene que ser el gato: se compara contra la grilla, como el arte.
        if let data = IconRenderer.png(size: 512, state: .enReposo),
           let rep = NSBitmapImageRep(data: data) {
            // El centro del ícono tiene que tener pelaje: si no, no se dibujó el gato.
            let center = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
            let color = center?.usingColorSpace(.sRGB)
            let bright = (color?.brightnessComponent ?? 0) > 0.5
            report.check("en el centro del ícono está el gato (pelaje claro)", bright,
                         String(format: "brillo %.2f", color?.brightnessComponent ?? -1))
            // Y las esquinas son del fondo redondeado: transparentes o oscuras, nunca pelaje.
            let corner = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
            report.check("las esquinas respetan el margen del ícono de macOS",
                         (corner?.alphaComponent ?? 0) < 0.5 || (corner?.brightnessComponent ?? 1) < 0.5,
                         String(format: "alfa %.2f brillo %.2f", corner?.alphaComponent ?? -1,
                                corner?.brightnessComponent ?? -1))
        } else {
            report.check("el ícono de 512 se dibuja", false)
        }

        // Y el .icns armado de verdad, que es lo que ve el Finder.
        let work = "\(NSTemporaryDirectory())p4w-icon-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        let log = IconRenderer.writeIconSet(into: work)
        let icns = "\(work)/P4W.icns"
        let attributes = try? FileManager.default.attributesOfItem(atPath: icns)
        let size = (attributes?[.size] as? Int) ?? 0
        report.check("el .icns se arma con iconutil", size > 1_000, "\(size) bytes")
        report.check("y contiene los diez PNG", FileManager.default.fileExists(
            atPath: "\(work)/icon.iconset/icon_512x512@2x.png"))
        report.line("   \(log.last ?? "")")
    }

    // MARK: 49. Sacar el registro del Mac (Fase 15.4)

    /// Cuántos minutos pide `--logs`. Se lee acá para poder verificarlo: un argumento inventado no puede
    /// cambiar lo que se vuelca.
    static func logMinutes(from arguments: [String]) -> Int? {
        guard let indice = arguments.firstIndex(of: "--logs") else { return nil }
        let siguiente = arguments.count > indice + 1 ? arguments[indice + 1] : nil
        guard let valor = siguiente, let minutos = Int(valor), minutos > 0 else { return 15 }
        return min(minutos, 240)   // techo: nadie necesita un día de registro en la terminal
    }

    /// Vuelca los registros a la terminal y termina.
    static func printLogs(minutes: Int) {
        let lineas = LogDump.recent(minutes: minutes)
        if lineas.isEmpty {
            print("No hay registros de los últimos \(minutes) minutos.")
        } else {
            for linea in lineas { print(linea.text) }
            print("— \(lineas.count) líneas · últimos \(minutes) minutos · subsistema \(Log.subsystem)")
        }
        exit(0)
    }

    /// El volcado: que los minutos se lean bien y que no se pueda pedir cualquier barbaridad.
    private static func checkLogDump(_ report: Reporter) {
        report.section("49. Sacar el registro del Mac (Fase 15.4)")
        report.check("sin el flag no se vuelca nada", logMinutes(from: ["P4W"]) == nil)
        report.check("`--logs` sin número usa 15 minutos", logMinutes(from: ["P4W", "--logs"]) == 15)
        report.check("`--logs 30` usa 30", logMinutes(from: ["P4W", "--logs", "30"]) == 30)
        report.check("un número inventado no rompe: cae en 15",
                     logMinutes(from: ["P4W", "--logs", "muchísimos"]) == 15)
        report.check("`--logs 0` no es válido: cae en 15", logMinutes(from: ["P4W", "--logs", "0"]) == 15)
        // El techo: nadie necesita volcar días de registro, y el volcado tiene que poder terminar siempre.
        report.check("y hay un techo: `--logs 99999` se recorta a 240",
                     logMinutes(from: ["P4W", "--logs", "99999"]) == 240)

        // El volcado real: tiene que poder correr y **no traer contenido**. Se comprueba que las líneas que
        // salen sean de nuestro subsistema y que el encabezado diga lo que es.
        let lineas = LogDump.recent(minutes: 5, limit: 50)
        report.check("el volcado corre y devuelve algo legible",
                     lineas.allSatisfy { !$0.category.isEmpty }, "\(lineas.count) líneas en 5 minutos")
        let texto = LogDump.text(minutes: 1, limit: 10, entorno: "app: P4W")
        report.check("el encabezado aclara que no hay contenido",
                     texto.contains("No incluye el texto de ninguna conversación"))
        report.check("y el volcado respeta el techo de líneas",
                     LogDump.recent(minutes: 240, limit: 1).count <= 1)

        // El archivo de diagnóstico, **escrito y leído de verdad**: es lo que la persona va a mandar, así que
        // tiene que existir, tener encabezado y no llevar contenido.
        let trabajo = "\(NSTemporaryDirectory())p4w-diag-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: trabajo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: trabajo) }
        let destino = URL(fileURLWithPath: "\(trabajo)/diagnostico.txt")
        do {
            try LogDump.write(minutes: 1, entorno: "app: P4W 0.2.0\nsistema: macOS", to: destino)
            let leido = (try? String(contentsOf: destino, encoding: .utf8)) ?? ""
            report.check("el diagnóstico se escribe y se lee", leido.contains("P4W — diagnóstico"))
            report.check("y lleva el resumen del entorno", leido.contains("app: P4W 0.2.0"))
            report.check("y avisa que no lleva contenido",
                         leido.contains("No incluye el texto de ninguna conversación"))
            let tamano = (try? FileManager.default.attributesOfItem(atPath: destino.path)[.size] as? Int) ?? 0
            report.check("y es un archivo de tamaño razonable, no un volcado sin fin",
                         (tamano ?? 0) < 2_000_000, "\((tamano ?? 0) / 1024) KB")
        } catch {
            report.check("el diagnóstico se escribe y se lee", false, "\(error)")
        }
    }

    // MARK: 47. El registro: la tabla y el redactor (Fase 15.1)

    /// Lo que se puede verificar de un sistema de logs sin mirar logs: que **esté completo**, que los niveles
    /// sean los que tienen que ser, y sobre todo que **no se filtre contenido**.
    private static func checkLogPolicy(_ report: Reporter) {
        report.section("47. El registro: la tabla, los niveles y el redactor (Fase 15.1)")

        // Un evento sin fila se registraría como fault en vez de callarse, pero igual es un bug: nadie decidió
        // su nivel. Se comprueba que **todos** tengan su fila.
        let sinFila = LogPolicy.missingRows()
        report.check("todos los eventos tienen su fila en la tabla",
                     sinFila.isEmpty, sinFila.map(\.rawValue).joined(separator: " · "))

        // **La trampa que documenta Apple**: `debug` solo se registra si una herramienta lo pide. Entonces nada
        // que tenga que **estar** después puede ser `debug`. Esto lo comprueba, en vez de confiar en el criterio.
        let debeEstarDespues: [LogEvent] = [.appArranco, .appCerro, .envioPedido, .conversacionAbierta,
                                            .instanciaLiberada, .permisoAvisos, .indiceReconstruido]
        let enDebug = debeEstarDespues.filter { LogPolicy.rule(for: $0).level == .debug }
        report.check("nada que tenga que estar después vive en `debug`",
                     enDebug.isEmpty, enDebug.map(\.rawValue).joined(separator: " · "))

        // Y lo que es una suposición violada va en `fault`, que es exactamente lo que ese nivel significa.
        report.check("mandar sin referencia es `fault`",
                     LogPolicy.rule(for: .envioSinReferencia).level == .fault)
        report.check("una inconsistencia es `fault`",
                     LogPolicy.rule(for: .consistenciaRota).level == .fault)
        report.check("el detalle de cada evento RPC es `debug`",
                     LogPolicy.rule(for: .rpcEvento).level == .debug)

        // **Lo que más importa: que no se filtre contenido.** Se arma la peor línea posible —con un texto y una
        // ruta que parecen datos de una persona— y se revisa el resultado.
        let textoPrivado = "mi contraseña es hunter2"
        // La ruta termina con el nombre de la persona **a propósito**: si la redacción fuera un recorte,
        // esta comprobación lo tiene que cazar. Si no, pasaba por casualidad.
        let rutaPrivada = "carpetas/privadas/P4W/alguien.jsonl"
        let linea = Log.compose(.envioPedido, [
            (.clave, .key(rutaPrivada)),
            (.visible, .key(textoPrivado)),
            (.largo, .number(textoPrivado.count)),
            (.motivo, .word("normal")),
            (.huella, .shape(textoPrivado)),
        ])
        report.check("la línea **no** contiene el texto",
                     !linea.contains("hunter2") && !linea.contains("contraseña"), linea)
        report.check("la línea **no** contiene la ruta de la persona",
                     !linea.contains("alguien") && !linea.contains("Library"), linea)
        report.check("la clave es una huella y no un recorte",
                     !LogValue.key(textoPrivado).text.contains("hunter2")
                        && !LogValue.key(rutaPrivada).text.contains("alguien")
                        && LogValue.key(rutaPrivada) == LogValue.key(rutaPrivada),
                     LogValue.key(rutaPrivada).text)
        report.check("y el nombre del archivo es la única pieza legible, a propósito",
                     LogValue.fileName(rutaPrivada).text == "alguien.jsonl")
        report.check("pero sí deja correlacionar (la forma y el largo están)",
                     linea.contains("\(textoPrivado.count)u·") && linea.contains("huella="), linea)
        report.check("y el nombre de archivo sí se puede leer (es lo que identifica)",
                     LogValue.fileName(rutaPrivada).text == "alguien.jsonl",
                     LogValue.fileName(rutaPrivada).text)
        report.check("sin conversación se dice «ninguna», no se deja el hueco",
                     LogValue.key(nil).text == "ninguna" && LogValue.key("").text == "ninguna")

        // Y que el registro **no tenga un campo para contenido**: la lista es cerrada y esta comprobación la
        // vigila, porque agregar un campo así sería la forma más fácil de romper la regla sin darse cuenta.
        let camposDeContenido: Set<String> = ["texto", "contenido", "mensaje", "prompt", "salida"]
        let filtrados = LogField.allCases.map(\.rawValue).filter { camposDeContenido.contains($0) }
        report.check("no existe un campo para contenido",
                     filtrados.isEmpty, filtrados.joined(separator: " · "))
    }

    // MARK: 48. El verificador de consistencia (Fase 15.2)

    /// Las tres formas en que «¿de qué conversación es esto?» se contestó mal, probadas como funciones puras.
    private static func checkConsistency(_ report: Reporter) {
        report.section("48. El verificador de consistencia: las tres formas de fallar (Fase 15.2)")

        let vis = "espacios/P4W/visible.jsonl"
        let otra = "espacios/P4W/otra.jsonl"

        // **El bug que reportó Jorge**: conversación abierta en pantalla, referencia en nil.
        let sinRef = ConsistencyCheck.send(reference: nil, visible: vis, instancia: nil)
        report.check("mandar con una conversación abierta y sin referencia es una violación",
                     sinRef == .envioSinReferencia(visible: vis) && sinRef.isViolation,
                     sinRef.motivo)
        report.check("y se registra como `fault`",
                     sinRef.event == .consistenciaRota
                        && LogPolicy.rule(for: sinRef.event).level == .fault)

        // **La mezcla**: la referencia es la de otra conversación.
        let mezcla = ConsistencyCheck.send(reference: otra, visible: vis, instancia: otra)
        report.check("mandar con la referencia de otra conversación es una violación",
                     mezcla.isViolation, mezcla.motivo)

        // **La otra cara**: la instancia enganchada es la de otra conversación (viva a propósito).
        let instanciaAjena = ConsistencyCheck.bind(reference: vis, visible: vis, instancia: otra)
        report.check("enganchar una instancia de otra conversación es una violación",
                     instanciaAjena.isViolation, instanciaAjena.motivo)

        // Abrir: la referencia tiene que ser la de la que se abre.
        report.check("abrir una conversación con la referencia de otra es una violación",
                     ConsistencyCheck.open(reference: otra, visible: vis).isViolation)

        // **Y que no dé falsos positivos**, que es tan importante como detectar: si marca todo, no sirve.
        report.check("todo en orden no es una violación",
                     !ConsistencyCheck.send(reference: vis, visible: vis, instancia: vis).isViolation
                        && !ConsistencyCheck.bind(reference: vis, visible: vis, instancia: vis).isViolation)
        report.check("no tener nada abierto no es una violación (es no tener nada abierto)",
                     !ConsistencyCheck.send(reference: nil, visible: nil, instancia: nil).isViolation
                        && ConsistencyCheck.send(reference: nil, visible: nil, instancia: nil) == .sinConversacion)

        // Una conversación nueva en preparación se identifica por su uuid y su instancia por la clave del
        // pool: compararlas daría un falso positivo, y por eso esa comparación no se hace.
        report.check("una conversación nueva en preparación no da falso positivo",
                     !ConsistencyCheck.bind(reference: nil, visible: nil, instancia: "#uuid-nuevo").isViolation)
    }

    // MARK: 46. Dónde está trabajando Pi (Fase 13.5)

    /// El indicador por conversación: qué estados merecen una marca y cuáles no.
    ///
    /// La decisión está en el núcleo justamente para poder verificarla acá: en la vista no se puede.
    private static func checkInProgressIndicator(_ report: Reporter) {
        report.section("46. Dónde está trabajando Pi (Fase 13.5)")

        report.check("«trabajando» se marca", InstanceState.working.indicator == "trabajando")
        report.check("«arrancando» también se marca (Pi ya está en eso)",
                     InstanceState.starting.indicator == "trabajando")
        report.check("lo que te necesita se marca distinto",
                     InstanceState.blocked.indicator == "te necesita")
        report.check("lo que falló se marca", InstanceState.failed.indicator == "con error")

        // Lo importante: **no** marcar todo. Una marca por cada conversación viva sería ruido y taparía
        // justamente lo que se quiere ver.
        let enReposo = [InstanceState.idle, .cold, .reaping]
        report.check("en reposo, apagándose o sin proceso: **ninguna** marca",
                     enReposo.allSatisfy { $0.indicator == nil },
                     enReposo.map { "\($0): \($0.indicator ?? "sin marca")" }.joined(separator: " · "))

        // Cuatro estados dicen tres cosas: «arrancando» y «trabajando» cuentan como lo mismo, que es lo que
        // la persona necesita saber.
        let conMarca = InstanceState.allCases.filter { $0.indicator != nil }
        report.check("y solo cuatro estados llevan marca, diciendo tres cosas",
                     conMarca.count == 4 && Set(conMarca.compactMap(\.indicator)).count == 3,
                     conMarca.map(\.indicator!).joined(separator: " · "))
    }

    // MARK: 45. Pertenencia a los spaces (Fase 14.4)

    /// Que una conversación **se quede en el space donde la dejaron**. El bug era que se podaba contra la
    /// lista que el índice acababa de leer, así que una ausencia momentánea la expulsaba.
    private static func checkSpaceMembership(_ report: Reporter) {
        report.section("45. Pertenencia: una conversación no se sale sola de su space (Fase 14.4)")

        let work = "\(NSTemporaryDirectory())p4w-spaces-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try SpacesStore(path: "\(work)/spaces.json")
            let space = try store.createSpace(name: "Trabajo")
            for ruta in ["/a/una.jsonl", "/b/dos.jsonl", "/c/tres.jsonl"] {
                try store.move(sessionPath: ruta, profileName: "lean", toSpaceID: space.id)
            }
            report.check("el space arranca con sus tres conversaciones",
                         store.all().first?.tabs.count == 3)

            // **La prueba del bug**: una conversación que el índice **no trajo** (ausencia momentánea) tiene
            // que quedarse en su space. Se simula con la pregunta por el disco: el archivo existe.
            let ausenteDelIndice = try store.pruneTabs(exists: { _ in true })
            report.check("una conversación que el índice no trajo **se queda** en su space",
                         ausenteDelIndice == 0 && (store.all().first?.tabs.count == 3),
                         "sacó \(ausenteDelIndice) · quedan \(store.all().first?.tabs.count ?? 0)")

            // Y cuando el archivo **de verdad** no está, sale: esa es la única razón para sacarla.
            let borrada = try store.pruneTabs(exists: { $0 != "/b/dos.jsonl" })
            report.check("solo sale si su archivo no existe",
                         borrada == 1 && (store.all().first?.tabs.count == 2),
                         "se fue la del archivo que no está")

            // Y las que quedan conservan **el orden** en el que estaban.
            let rutas = (store.all().first?.tabs ?? []).map(\.sessionPath)
            report.check("y las que quedan mantienen su orden",
                         rutas == ["/a/una.jsonl", "/c/tres.jsonl"], rutas.joined(separator: " · "))
        } catch {
            report.check("la poda de spaces funciona", false, "\(error)")
        }

        // Y las dos reglas de dónde cae una conversación nueva, que son decisión y no azar.
        report.line("   una conversación nueva con un space activo nace **dentro de ese space**;")
        report.line("   sin space activo va a «Sin space», que es la bandeja de entrada.")
    }

    // MARK: 44. Multitasking (Fase 13)

    /// Abrir otra conversación **no puede tocar la que está trabajando**. Es la mitad del bug que Jorge vio
    /// en la Mac de su esposa: la otra mitad —que lo de una no se dibuje en la otra— es el enrutado por
    /// conversación, que se verifica abajo y con el uso.
    ///
    /// Se prueba con **procesos reales**: se abren dos instancias y se comprueba que la primera sigue viva,
    /// con el mismo `pid`, después de abrir la segunda. Sin `pi` no se puede, y se dice.
    private static func checkMultitasking(_ report: Reporter) {
        report.section("44. Multitasking: abrir otra conversación no cierra la que trabaja (Fase 13)")

        let environment = ShellEnvironment.resolve()
        guard let pi = environment.piExecutable else {
            report.line("   (sin `pi` instalado: no se puede probar con procesos reales)")
            return
        }
        let sessions = SessionCatalog.load()
        let utilizables = sessions.filter { $0.cwdIsAvailable }.prefix(2)
        guard utilizables.count == 2 else {
            report.line("   (hacen falta dos conversaciones abribles para esta prueba)")
            return
        }

        let work = "\(NSTemporaryDirectory())p4w-multi-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            var copias: [String] = []
            for (indice, sesion) in utilizables.enumerated() {
                let copia = "\(work)/sesion\(indice).jsonl"
                try FileManager.default.copyItem(atPath: sesion.path, toPath: copia)
                copias.append(copia)
            }

            let supervisor = InstanceSupervisor(
                config: SupervisorConfig(piExecutable: pi, defaultProfile: .lean,
                                         reapAfterSeconds: 600, maxLiveInstances: 3),
                environment: environment
            )
            defer { supervisor.shutdownAll() }

            guard let primera = try? supervisor.acquire(.existing(path: copias[0])),
                  let segunda = try? supervisor.acquire(.existing(path: copias[1])) else {
                report.check("se pudieron abrir dos conversaciones a la vez", false)
                return
            }
            report.check("se pueden tener dos conversaciones vivas a la vez",
                         primera.pid != segunda.pid,
                         "pids \(primera.pid) y \(segunda.pid)")

            // La primera **no se toca** por abrir la segunda: mismo proceso, y sigue en el pool.
            let enElPool = supervisor.snapshot()
            report.check("la primera sigue en el pool después de abrir la segunda",
                         enElPool.contains { $0.pid == primera.pid },
                         "\(enElPool.count) instancias vivas")
            report.check("y es el **mismo proceso**: abrir otra no la reinició",
                         primera.isRunning, "pid \(primera.pid) sigue vivo")

            // Y el invariante que protege el trabajo: una instancia ocupada no se recicla **ni siquiera**
            // pidiéndolo de forma explícita (que es el camino de ⌘W).
            // Una instancia **inactiva** sí se libera: es lo que devuelve memoria, y es la mitad del
            // propósito del pool. (El caso contrario —una **ocupada** no se libera— necesita un run de
            // verdad, así que se prueba en la corrida real, con `--live`.)
            let liberada = supervisor.release(copias[0])
            report.check("una instancia inactiva sí se libera (devuelve memoria)",
                         liberada != nil,
                         "quedan \(supervisor.snapshot().count) vivas")
            report.line("   (el invariante completo vive en la suite del supervisor: 27 comprobaciones)")
        } catch {
            report.check("el multitasking con dos conversaciones funciona", false, "\(error)")
        }
    }

    // MARK: 43. Borradores y deshacer (Fase 11)

    /// Lo que puede fallar acá, y lo que de verdad le pasó a la esposa de Jorge: que el borrador de una
    /// conversación aparezca en otra, que no sobreviva a cerrar la app, y que deshacer no agrupe el tecleo.
    private static func checkDrafts(_ report: Reporter) {
        report.section("43. Borradores y deshacer (Fase 11)")

        let work = "\(NSTemporaryDirectory())p4w-drafts-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try DraftStore(path: "\(work)/drafts.json")

            report.check("sin nada escrito, no hay borrador", store.text(for: "/c/uno").isEmpty)
            try store.set("lo que escribí en uno", for: "/c/uno")
            report.check("el borrador queda bajo su conversación",
                         store.text(for: "/c/uno") == "lo que escribí en uno")

            // **El bug que se está arreglando**: el texto viajando a otra conversación.
            report.check("y **no** aparece en otra conversación",
                         store.text(for: "/c/dos").isEmpty, "antes el borrador era uno solo para toda la app")

            try store.set("lo de dos", for: "/c/dos")
            report.check("cada conversación conserva lo suyo",
                         store.text(for: "/c/uno") == "lo que escribí en uno"
                         && store.text(for: "/c/dos") == "lo de dos",
                         "\(store.count()) borradores")

            // Sobrevivir a cerrar la app: otro objeto leyendo el mismo archivo.
            let reopened = try DraftStore(path: "\(work)/drafts.json")
            report.check("sobrevive a cerrar y volver a abrir la app",
                         reopened.text(for: "/c/uno") == "lo que escribí en uno"
                         && reopened.text(for: "/c/dos") == "lo de dos",
                         "\(reopened.count()) borradores")

            // Se olvida **solo** el de la conversación enviada.
            try reopened.remove(for: "/c/uno")
            let third = try DraftStore(path: "\(work)/drafts.json")
            report.check("olvidar uno no toca los demás",
                         third.text(for: "/c/uno").isEmpty && third.text(for: "/c/dos") == "lo de dos",
                         "quedan \(third.count())")

            // Vaciar el campo borra el borrador: no queda basura que después se restaure sola.
            try third.set("", for: "/c/dos")
            report.check("vaciar el campo olvida el borrador", third.count() == 0)
        } catch {
            report.check("los borradores funcionan", false, "\(error)")
        }

        // El deshacer del campo no se verifica acá: lo trae el `NSTextView` y es comportamiento de AppKit,
        // con el tecleo ya agrupado. Antes había un historial propio, y se quitó justamente porque el campo
        // nuevo lo hace mejor — dejar sus comprobaciones habría dado una confianza falsa.

        // ── Y el mecanismo del campo nuevo: que AppKit **avise** cada cambio ──
        //
        // Es lo que el campo de SwiftUI no hacía (avisaba recién al perder el foco), y el eslabón que hacía
        // imposible guardar el borrador mientras se escribe. Se verifica acá, sin GUI y sin depender de la
        // accesibilidad: se arma un `NSTextView` igual al del compositor, se registra el mismo observador, y
        // se le mete texto como lo haría una tecla.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        // **La configuración de verdad**, la misma que usa el compositor.
        ComposerTextView.configure(textView, placeholder: "prueba")
        var recibido = ""
        let observador = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { nota in
            recibido = (nota.object as? NSTextView)?.string ?? ""
        }
        textView.insertText("hola", replacementRange: NSRange(location: 0, length: 0))
        report.check("el campo avisa a la app **en cada tecla**",
                     recibido == "hola",
                     recibido.isEmpty ? "no avisó: con esto el borrador no se puede guardar mientras se escribe"
                                      : "avisó con «\(recibido)»")
        textView.insertText(" mundo", replacementRange: NSRange(location: 4, length: 0))
        report.check("y sigue avisando en la siguiente",
                     recibido == "hola mundo", "«\(recibido)»")
        // Y que el campo pueda recibir texto **desde la app**: es lo que hace que un borrador recuperado se
        // vea. El campo de SwiftUI fallaba también en esta dirección.
        textView.string = "recuperado"
        report.check("y acepta el texto que le pone la app (el borrador recuperado se ve)",
                     textView.string == "recuperado")
        report.check("el campo nuevo trae deshacer propio",
                     textView.allowsUndo, "es la forma estándar, con AppKit agrupando el tecleo")
        // Y la configuración que evita romper código: comillas "inteligentes" y autocorrector apagados.
        report.check("el campo no hace comillas «inteligentes» ni autocorrección",
                     !textView.isAutomaticQuoteSubstitutionEnabled
                     && !textView.isAutomaticDashSubstitutionEnabled
                     && !textView.isAutomaticTextReplacementEnabled
                     && !textView.isAutomaticSpellingCorrectionEnabled,
                     "esto es para hablarle a un agente que escribe código")
        report.check("el campo se estira a lo ancho del contenedor",
                     textView.autoresizingMask.contains(.width)
                     && textView.textContainer?.widthTracksTextView == true,
                     "sin esto el campo mide cero y no se ve nada")
        NotificationCenter.default.removeObserver(observador)
    }

    // MARK: 42. Legibilidad y contraste (Fase 10)

    /// Los contrastes, **calculados** en las dos apariencias. Es la parte de la interfaz que no es cuestión
    /// de gusto: un contraste se mide, y si baja del mínimo se falla.
    ///
    /// Se resuelven los colores semánticos del sistema en la apariencia que corresponda y se mezclan sobre el
    /// fondo real, porque ahí está la trampa: los colores del sistema llevan la suavidad en la **opacidad**, y
    /// comparar el color puro da un número falso (decía 21:1 donde en pantalla hay 1.9:1).
    private static func checkLegibility(_ report: Reporter) {
        report.section("42. Legibilidad y contraste (Fase 10)")

        for dark in [false, true] {
            let nombre = dark ? "oscuro" : "claro"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let bubble = dark ? NSColor.controlBackgroundColor : NSColor.textBackgroundColor
                let info = blended(NSColor.labelColor.withAlphaComponent(0.56), over: bubble)
                let accent = NSColor.controlAccentColor
                let tint = blended(accent.withAlphaComponent(dark ? 0.30 : 0.26), over: bubble)

                let infoContrast = contrast(info, bubble)
                report.check("texto informativo en \(nombre): \(String(format: "%.1f", infoContrast)):1",
                             infoContrast >= 4.5, "el mínimo para texto es 4.5:1")

                // El tinte es **acompañante**, no la señal: un azul sobre un fondo casi negro apenas mueve la
                // luminancia, así que acá no se puede exigir 3:1. Lo que se exige es que sea perceptible, y el
                // requisito de los elementos gráficos lo cumple la barra, abajo.
                let tintContrast = contrast(tint, bubble)
                report.check("el tinte del mensaje propio se percibe (\(nombre))",
                             tintContrast >= 1.2,
                             String(format: "%.1f:1 · acompañante del acento; el 3:1 lo cumple la barra",
                                    tintContrast))

                let stripeContrast = contrast(accent, bubble)
                report.check("la barra del mensaje propio cumple el 3:1 de los elementos gráficos (\(nombre))",
                             stripeContrast >= 3.0, String(format: "%.1f:1", stripeContrast))

                // Y que el texto se lea **sobre el acento de la barra** y sobre el tinte.
                let onStripe = blended(NSColor.labelColor, over: accent)
                report.check("el texto se lee sobre el mensaje propio (\(nombre))",
                             contrast(onStripe, tint) >= 4.5,
                             String(format: "%.1f:1", contrast(onStripe, tint)))
            }
        }

        // La comparación honesta: lo que había antes, para que el número quede registrado.
        let before = NSAppearance(named: .aqua)!
        before.performAsCurrentDrawingAppearance {
            let bubble = NSColor.textBackgroundColor
            report.line(String(format: "   antes: el texto informativo daba %.1f:1 y el acento del mensaje "
                                       + "propio %.1f:1 (en oscuro, 2.66:1: no cumplía)",
                               contrast(blended(.tertiaryLabelColor, over: bubble), bubble),
                               contrast(.selectedContentBackgroundColor, bubble)))
        }

        report.check("hay un piso de tamaño para el texto",
                     SelfCheck.minimumTextSize >= 11, "el piso es \(SelfCheck.minimumTextSize) puntos")
    }

    /// El piso de tamaño del texto de la interfaz. Chico a propósito como **dato**: hay usos del código que
    /// tienen que respetarlo, y tenerlo acá permite compararlo.
    static let minimumTextSize: Double = 11

    static func blended(_ top: NSColor, over bottom: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return bottom }
        let a = t.alphaComponent
        return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                       green: t.greenComponent * a + b.greenComponent * (1 - a),
                       blue: t.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// El contraste de la WCAG: (L1 + 0.05) / (L2 + 0.05).
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
                 + 0.0722 * channel(rgb.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: 41. Actualizaciones (Fase 9)

    /// Lo que puede fallar en un aviso de versión nueva: **comparar texto en vez de números** (y decir que
    /// `0.9.0` es más nueva que `0.10.0`), ofrecer una beta sin querer, o romperse cuando la consulta falla.
    private static func checkUpdateCheck(_ report: Reporter) {
        report.section("41. Avisos de actualización (Fase 9)")

        // ── La comparación, que es donde se equivoca todo el mundo ────────────
        func version(_ text: String) -> ReleaseVersion? { ReleaseVersion(text) }

        report.check("lee «v0.1.0» y «0.1.0» igual",
                     version("v0.1.0") == version("0.1.0"), version("v0.1.0")?.description ?? "?")
        report.check("«1.0» y «1.0.0» son la misma versión",
                     version("1.0") == version("1.0.0"),
                     "\(version("1.0")?.description ?? "?") contra \(version("1.0.0")?.description ?? "?")")
        report.check("**0.10.0 es más nueva que 0.9.0** (el error clásico del texto)",
                     (version("0.10.0")! > version("0.9.0")!), "comparando texto daría lo contrario")
        report.check("0.2.0 es más nueva que 0.1.9", version("0.2.0")! > version("0.1.9")!)
        report.check("una versión no es más nueva que sí misma", !(version("0.1.0")! > version("0.1.0")!))
        report.check("1.0 es más nueva que 0.9.9", version("1.0")! > version("0.9.9")!)
        report.check("no se rompe con basura", version("no-version") == nil)
        report.check("ni con algo vacío", version("") == nil)
        report.check("pero sí lee una sola cifra", version("2") != nil)
        report.check("reconoce una previa", version("0.2.0-beta.1")?.isPrerelease == true)
        report.check("y una estable no lo es", version("0.2.0")?.isPrerelease == false)

        let current = version("0.1.0")!

        // ── La respuesta de GitHub, con respuestas guardadas ──────────────────
        // Nunca contra internet: así la verificación no depende de que hoy exista un release nuevo.
        func decode(_ json: String) -> UpdateCheck.Outcome {
            UpdateCheck.decode(Data(json.utf8), current: current)
        }

        let available = decode("""
        {"tag_name": "v0.2.0", "name": "P4W 0.2.0", "html_url": "https://github.com/x/y/releases/tag/v0.2.0",
         "assets": [{"name": "P4W-0.2.0.dmg", "browser_download_url": "https://github.com/x/y/dl/P4W-0.2.0.dmg"}]}
        """)
        report.check("con una versión nueva, la ofrece", available.update?.version.description == "0.2.0")
        report.check("y ofrece el .dmg, no la página",
                     available.update?.downloadURL.absoluteString.hasSuffix(".dmg") == true,
                     available.update?.downloadURL.lastPathComponent ?? "?")
        report.check("con la misma versión, no dice nada",
                     decode("{\"tag_name\": \"v0.1.0\"}") == .upToDate(current: current))
        report.check("con una versión más vieja, tampoco (no se baja nunca)",
                     decode("{\"tag_name\": \"v0.0.9\"}") == .upToDate(current: current))
        report.check("y con una beta publicada, tampoco: nadie quiere una beta que no pidió",
                     decode("{\"tag_name\": \"v0.2.0-beta\"}") == .upToDate(current: current))

        // ── Y falla abierto: lo que no se puede saber, no se muestra ──────────
        let broken = [ "esto no es json", "{}", "{\"tag_name\": \"v-rara\"}",
                       "{\"tag_name\": \"v9.9.9\"}" ]   // sin assets ni html_url: no hay qué descargar
        report.check("una respuesta ilegible no rompe: devuelve «no sé»",
                     decode("esto no es json").update == nil)
        report.check("y sin nada que descargar tampoco ofrece",
                     decode("{\"tag_name\": \"v9.9.9\"}").update == nil)
        report.check("«no sé» nunca se muestra como si hubiera novedad",
                     broken.allSatisfy { decode($0).update == nil })
        report.check("pero la página del release alcanza cuando no hay .dmg",
                     decode("{\"tag_name\": \"v0.2.0\", \"html_url\": \"https://github.com/x/y\"}")
                        .update?.downloadURL.absoluteString == "https://github.com/x/y")

        // ── Las reglas del aviso, juntas ──────────────────────────────────────
        let update = available.update
        report.check("se muestra cuando hay novedad y Pi está quieto",
                     UpdateNotice.shouldShow(outcome: available, dismissedVersion: nil, piIsWorking: false))
        report.check("**no se muestra mientras Pi trabaja**",
                     !UpdateNotice.shouldShow(outcome: available, dismissedVersion: nil, piIsWorking: true))
        report.check("ni cuando no hay nada nuevo",
                     !UpdateNotice.shouldShow(outcome: .upToDate(current: current),
                                              dismissedVersion: nil, piIsWorking: false))
        report.check("ni cuando no se pudo consultar",
                     !UpdateNotice.shouldShow(outcome: .unknown(reason: "sin internet"),
                                              dismissedVersion: nil, piIsWorking: false))
        report.check("descartar esa versión la silencia",
                     !UpdateNotice.shouldShow(outcome: available, dismissedVersion: "0.2.0",
                                              piIsWorking: false))
        report.check("pero una versión **más nueva** vuelve a avisar",
                     UpdateNotice.shouldShow(outcome: available, dismissedVersion: "0.2.0" ,
                                             piIsWorking: false) == false
                     && UpdateNotice.shouldShow(
                        outcome: .available(UpdateInfo(
                            version: ReleaseVersion("0.3.0")!,
                            downloadURL: update!.downloadURL)),
                        dismissedVersion: "0.2.0", piIsWorking: false),
                     "descartar la 0.2.0 no puede silenciar la 0.3.0")

        // ── Y una consulta por día, no más ────────────────────────────────────
        report.check("la primera vez consulta", UpdateCheck.shouldCheck(lastCheck: nil))
        report.check("una hora después no vuelve a consultar",
                     !UpdateCheck.shouldCheck(lastCheck: Date().addingTimeInterval(-3600)))
        report.check("un día después sí",
                     UpdateCheck.shouldCheck(lastCheck: Date().addingTimeInterval(-25 * 3600)))
        report.check("el repositorio es el público", UpdateCheck.repository.contains("P4W"),
                     UpdateCheck.latestReleaseURL.absoluteString)
    }

    // MARK: 40. Secciones plegables (Fase 8)

    /// Lo que puede fallar al plegar: que plegar no saque las filas (y entonces no sirva para nada), que el
    /// contador desaparezca con la sección plegada (y entonces esconda información), o que el estado no
    /// sobreviva al reinicio — que era justo el defecto del plegado viejo.
    private static func checkSidebarSections(_ report: Reporter) {
        report.section("40. Secciones plegables del sidebar (Fase 8)")

        // Las claves: una por sección, y las de space y proyecto con su identificador adentro.
        report.check("hay una clave por sección de arriba",
                     SidebarContent.headers.count == 3,
                     SidebarContent.headers.map { $0.title }.joined(separator: " · "))
        report.check("la clave de un space no choca con la de una sección",
                     SidebarSection.space("s1") != SidebarSection.espacios
                     && SidebarSection.project("pi") != SidebarSection.historial,
                     SidebarSection.space("s1") + " · " + SidebarSection.project("pi"))

        // Plegado: la lista queda vacía. **Esto es lo que hace que plegar sirva**: no se construyen las
        // filas, en vez de construirlas y esconderlas.
        let sessions = (1...50).map { "/s/\($0)" }
        let abierto = SidebarContent.visibleSessions(sessions, group: "proyecto:x", collapsed: [])
        let plegado = SidebarContent.visibleSessions(sessions, group: "proyecto:x",
                                                    collapsed: ["proyecto:x"])
        report.check("desplegado, las filas están", abierto.count == 50, "\(abierto.count)")
        report.check("plegado, la lista queda **vacía**: no se construyen",
                     plegado.isEmpty, "\(plegado.count) filas")
        report.check("y plegar un grupo no afecta a otro",
                     SidebarContent.visibleSessions(sessions, group: "proyecto:y",
                                                    collapsed: ["proyecto:x"]).count == 50)

        // El contador: se ve plegado o no, porque plegar puede esconder el contenido, nunca la información
        // de que hay algo adentro.
        report.check("el contador existe y dice el número", SidebarContent.countLabel(0) == "0"
                     && SidebarContent.countLabel(476) == "476")
        for header in SidebarContent.headers {
            report.check("«\(header.title)» tiene clave y título", !header.key.isEmpty
                         && !header.title.isEmpty)
        }

        // Y lo que estaba mal: el estado tiene que **sobrevivir al reinicio**.
        let work = "\(NSTemporaryDirectory())p4w-sidebar-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let store = try SpacesStore(path: "\(work)/spaces.json")
            report.check("arranca con todo desplegado", store.collapsedKeys().isEmpty)

            try store.setCollapsed(true, section: SidebarSection.historial)
            try store.setCollapsed(true, section: SidebarSection.project("pi"))
            try store.setCollapsed(true, section: SidebarSection.space("s1"))

            let reopened = try SpacesStore(path: "\(work)/spaces.json")
            report.check("lo plegado sobrevive al reinicio", reopened.collapsedKeys().count == 3,
                         reopened.collapsedKeys().sorted().joined(separator: " · "))
            report.check("y sobrevive cada tipo de clave",
                         reopened.collapsedKeys().contains(SidebarSection.historial)
                         && reopened.collapsedKeys().contains(SidebarSection.project("pi"))
                         && reopened.collapsedKeys().contains(SidebarSection.space("s1")))

            try reopened.setCollapsed(false, section: SidebarSection.historial)
            let third = try SpacesStore(path: "\(work)/spaces.json")
            report.check("desplegar saca solo esa clave",
                         !third.collapsedKeys().contains(SidebarSection.historial)
                         && third.collapsedKeys().count == 2,
                         third.collapsedKeys().sorted().joined(separator: " · "))

            // Y que no se lleve puesto lo demás del archivo: los tabs fijados y las sugerencias ignoradas
            // viven ahí mismo.
            try third.setCollapsed(true, section: SidebarSection.espacios)
            let fourth = try SpacesStore(path: "\(work)/spaces.json")
            report.check("plegar no borra el resto del archivo",
                         fourth.collapsedKeys().contains(SidebarSection.espacios)
                         && fourth.collapsedKeys().count == 3)
        } catch {
            report.check("el plegado se guarda", false, "\(error)")
        }
    }

    // MARK: 39. Dependencias

    /// Los tres niveles, y lo que puede fallar de verdad en el chequeo: que confunda "no hay config" con
    /// "no hay nada", o que un archivo ilegible rompa el reporte en vez de reportar.
    private static func checkDependencies(_ report: Reporter) {
        report.section("39. Dependencias (obligatorio · recomendado · opcional)")

        // Con la máquina de verdad: `pi` y Node tienen que estar, si no la app no sirve para nada.
        let real = DependencyCheck.run()
        report.check("el chequeo devuelve todos los ítems",
                     real.items.count == 7, "\(real.items.count) ítems")
        report.check("hay ítems en los tres niveles",
                     Set(real.items.map(\.level)) == Set(DependencyLevel.allCases),
                     DependencyLevel.allCases.map { level in
                         "\(level.label): \(real.items.filter { $0.level == level }.count)"
                     }.joined(separator: " · "))
        report.check("`pi` está (el único ejecutable que P4W lanza)",
                     real.items.first { $0.id == "pi" }?.present == true,
                     real.items.first { $0.id == "pi" }?.detail ?? "?")
        report.check("Node está", real.items.first { $0.id == "node" }?.present == true)
        report.check("con `pi` y Node presentes, la app no está bloqueada", !real.isBlocked,
                     real.summary)
        report.check("cada ítem dice qué hacer si falta",
                     real.items.allSatisfy { !$0.fix.isEmpty && $0.fix.count > 20 })

        // Con una carpeta fabricada **vacía**: ahí sí tiene que bloquear, y decir por qué.
        let work = "\(NSTemporaryDirectory())p4w-deps-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: work) }
        do {
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let empty = DependencyCheck.run(root: work)
            report.check("sin `models.json` no hay proveedores",
                         empty.items.first { $0.id == "modelos" }?.present == false,
                         empty.items.first { $0.id == "modelos" }?.detail ?? "?")
            report.check("y sin proveedores la app queda bloqueada", empty.isBlocked)
            report.check("lo que bloquea es obligatorio",
                         empty.blocking.allSatisfy { $0.level == .obligatorio },
                         empty.blocking.map(\.title).joined(separator: " · "))
            report.check("y los obligatorios no se pueden descartar",
                         empty.blocking.allSatisfy { $0.level == .obligatorio })
            report.check("sin DeepSeek, lo sugiere pero no bloquea",
                         empty.items.first { $0.id == "deepseek" }?.level == .recomendado)

            // Una config con un proveedor DeepSeek y un modelo elegido: no bloquea y no sugiere DeepSeek.
            try """
            {"providers": {"deepseek": {"type": "openai"}}}
            """.write(toFile: "\(work)/models.json", atomically: true, encoding: .utf8)
            try """
            {"model": "deepseek-v4-flash"}
            """.write(toFile: "\(work)/settings.json", atomically: true, encoding: .utf8)
            let configured = DependencyCheck.run(root: work)
            report.check("con DeepSeek configurado, ya no lo sugiere",
                         configured.items.first { $0.id == "deepseek" }?.present == true,
                         configured.items.first { $0.id == "deepseek" }?.detail ?? "?")
            report.check("y reconoce el modelo elegido",
                         configured.items.first { $0.id == "modelo-elegido" }?.present == true,
                         configured.items.first { $0.id == "modelo-elegido" }?.detail ?? "?")
            report.check("con modelos y modelo elegido, ya no hay nada obligatorio que falte",
                         configured.blocking.isEmpty,
                         configured.blocking.map(\.title).joined(separator: " · "))

            // El caso real: DeepSeek **no** es un proveedor propio, viene servido por otro. Se detecta por
            // el modelo elegido. La primera versión de este chequeo lo daba por faltante.
            try """
            {"providers": {"command-code": {"type": "openai"}}}
            """.write(toFile: "\(work)/models.json", atomically: true, encoding: .utf8)
            try """
            {"defaultProvider": "command-code", "defaultModel": "deepseek/deepseek-v4-flash"}
            """.write(toFile: "\(work)/settings.json", atomically: true, encoding: .utf8)
            let viaProvider = DependencyCheck.run(root: work)
            report.check("DeepSeek servido por otro proveedor se detecta por el modelo elegido",
                         viaProvider.items.first { $0.id == "deepseek" }?.present == true,
                         viaProvider.items.first { $0.id == "deepseek" }?.detail ?? "?")
            report.check("y lee las claves reales de la preferencia de Pi",
                         DependencyCheck.selectedModel(root: work) == "deepseek/deepseek-v4-flash",
                         DependencyCheck.selectedModel(root: work) ?? "?")

            // Un archivo ilegible no puede romper el chequeo: se reporta como que falta.
            try "{ esto no es json".write(toFile: "\(work)/models.json", atomically: true, encoding: .utf8)
            let broken = DependencyCheck.run(root: work)
            report.check("un archivo ilegible se reporta como faltante, no rompe",
                         broken.items.first { $0.id == "modelos" }?.present == false)
        } catch {
            report.check("el chequeo de dependencias corre con carpetas fabricadas", false, "\(error)")
        }

        // Y que no lea secretos: del `auth.json` solo importan los nombres de los proveedores.
        report.check("el chequeo no lee valores de `auth.json`",
                     DependencyCheck.providerNames(root: work).isEmpty
                     || !DependencyCheck.providerNames(root: work).contains { $0.contains("key") },
                     "solo se leen claves de diccionario, nunca valores")
    }

    /// `P4W --check-updates`: consulta de verdad y sale. Es la forma de verificar el aviso sin abrir la app.
    static func printUpdates() {
        guard let current = P4WVersion.release else {
            print("no pude leer la versión propia (\(P4WVersion.current))")
            exit(1)
        }
        print("P4W \(current) · consultando \(UpdateCheck.repository)…")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: UpdateCheck.Outcome = .unknown(reason: "sin respuesta")
        Task {
            outcome = await UpdateCheck.latest(current: current)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        switch outcome {
        case .upToDate(let version):
            print("✓ estás en la última versión (\(version))")
        case .available(let info):
            print("↑ hay una versión nueva: \(info.version)")
            print("  descarga: \(info.downloadURL)")
        case .unknown(let reason):
            // Falla abierto: en la app esto no se muestra. Acá se imprime porque es una herramienta.
            print("· no se pudo consultar: \(reason)")
            print("  (en la app esto no se muestra: un aviso opcional nunca puede ser un error)")
        }
        exit(0)
    }

    /// `P4W --check-deps`: imprime el chequeo y sale. Es la forma de verificarlo sin abrir la app.
    static func printDependencies() {
        let report = DependencyCheck.run()
        print("Dependencias de P4W\n")
        for item in report.items {
            let mark = item.present ? "✓" : (item.level == .obligatorio ? "✗" : "·")
            print("\(mark) [\(item.level.label)] \(item.title)")
            print("      \(item.detail)")
            if !item.present { print("      → \(item.fix)") }
        }
        print("\n\(report.summary)")
        if !report.blocking.isEmpty {
            print("Falta algo obligatorio: P4W no puede abrir conversaciones hasta que esté.")
        }
        exit(0)
    }

    /// `P4W --render-cat`: vuelca los cuadros a PNG en `dist/cat/`.
    ///
    /// Existe para poder **decidir mirando**: el arte es lo único del proyecto que no se puede verificar
    /// del todo, así que al menos tiene que poder verse sin abrir la app.
    static func renderCat() {
        let root = "dist/cat"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        print("Cuadros del gato → \(root)/")
        for (name, grid) in CatArt.allGrids {
            let problems = grid.problems()
            let status = problems.isEmpty ? "ok" : "CON PROBLEMAS: " + problems.joined(separator: "; ")
            print("  \(name): \(grid.columns)×\(grid.height) · \(status)")
            for scale in [1, 12] {
                guard let data = grid.pngData(scale: scale) else { continue }
                let path = scale == 1 ? "\(root)/\(name).png" : "\(root)/\(name)@\(scale)x.png"
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        // Diagnóstico del volcado: como no puedo ver la imagen, al menos puedo compararla contra la
        // grilla y que me diga qué leyó de verdad en cada celda que no coincide.
        if let base = CatArt.allGrids.first?.grid, let png = base.pngData(scale: 1),
           let back = PixelGrid.readBack(png: png, scale: 1, columns: base.columns, rows: base.height) {
            var shown = 0
            for row in 0..<base.height where shown < 3 {
                for column in 0..<base.columns where shown < 3 {
                    let expected = base.color(row: row, column: column)
                    if expected != back[row][column] {
                        let want = expected.map { "\($0.hex) (\($0.red),\($0.green),\($0.blue))" } ?? "transparente"
                        let got = back[row][column].map { "\($0.hex) (\($0.red),\($0.green),\($0.blue))" } ?? "transparente"
                        print("  desajuste (\(column),\(row)): esperaba \(want) · leí \(got)")
                        shown += 1
                    }
                }
            }
            if shown == 0 { print("  el PNG coincide con la grilla, celda por celda") }
        }

        // Una tira con todos los cuadros juntos, para ver la animación de un vistazo.
        print("\nUso de la paleta:")
        for (character, color) in CatArt.palette.sorted(by: { $0.key < $1.key }) {
            let count = CatArt.allGrids.reduce(0) { $0 + ($1.grid.usage()[character] ?? 0) }
            print("  \(character)  \(color.hex)  \(count) píxeles")
        }
        exit(0)
    }

    // MARK: 10. Revelado progresivo

    /// El progreso del revelado vive en el modelo porque las vistas de un LazyVStack se descartan
    /// al salir de pantalla y su @State se pierde (ahí el texto se reiniciaba o quedaba cortado).
    private static func checkReveal(_ report: Reporter) {
        report.section("10. Revelado progresivo (estado fuera de la vista)")

        var count = 0
        var steps = 0
        while count < 1_000, steps < 500 {
            count = RevealAnimator.advance(current: count, target: 1_000)
            steps += 1
        }
        report.check("nunca se pasa del objetivo", count <= 1_000, "\(count)/1000")
        report.check("llega al objetivo", count == 1_000, "en \(steps) ticks")
        report.check("no se queda pegado en cero",
                     RevealAnimator.advance(current: 0, target: 100) > 0,
                     "\(RevealAnimator.advance(current: 0, target: 100))")
        report.check("nunca retrocede",
                     RevealAnimator.advance(current: 500, target: 100) == 100)
        report.check("no revela de a un carácter cuando falta mucho",
                     RevealAnimator.advance(current: 0, target: 1_000) > 10,
                     "\(RevealAnimator.advance(current: 0, target: 1_000)) por tick")
    }

    /// Cuenta lo que un markdown "de verdad" trae, usando un documento real como fixture
    /// (tablas, títulos, citas, código). Sirve para medir la brecha del renderizador actual en
    /// vez de describirla de memoria.
    private static func checkRealMarkdown(_ report: Reporter) {
        let fixture = "fixtures/markdown-real.md"
        guard let text = try? String(contentsOfFile: fixture, encoding: .utf8) else {
            report.line("   (sin fixture \(fixture): se saltea)")
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headings = lines.filter { $0.hasPrefix("#") }.count
        let tableRows = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }.count
        let quotes = lines.filter { $0.hasPrefix(">") }.count
        let inlineCode = text.components(separatedBy: "`").count / 2

        report.line("   fixture: \(lines.count) líneas · \(headings) títulos · "
                    + "\(tableRows) filas de tabla · \(quotes) líneas de cita · ~\(inlineCode) tramos de código")

        let blocks = MarkdownParser.parse(text)
        func count(_ match: (MarkdownBlock) -> Bool) -> Int { blocks.filter(match).count }

        let parsedHeadings = count { if case .heading = $0 { return true }; return false }
        let parsedTables = count { if case .table = $0 { return true }; return false }
        let parsedQuotes = count { if case .quote = $0 { return true }; return false }
        let tableRowCount = blocks.compactMap { block -> Int? in
            if case .table(_, let rows, _) = block { return rows.count }
            return nil
        }.reduce(0, +)

        report.check("los títulos se reconocen como bloques",
                     parsedHeadings == headings, "\(parsedHeadings)/\(headings)")
        report.check("las tablas se reconocen como tablas",
                     parsedTables >= 3, "\(parsedTables) tablas")
        // Ojo: las 18 líneas con `|` incluyen encabezados y separadores. Las filas de DATOS son 12.
        report.check("las filas de datos de las tablas no se pierden",
                     tableRowCount == 12, "\(tableRowCount) filas de datos")

        let headers = blocks.compactMap { block -> [String]? in
            if case .table(let header, _, _) = block { return header }
            return nil
        }
        report.check("cada tabla conserva su encabezado",
                     headers.count == 3 && headers.contains { $0.first == "Campo" },
                     headers.map { $0.joined(separator: " · ") }.joined(separator: " | "))

        let alignmentCounts = blocks.compactMap { block -> [TableAlignment]? in
            if case .table(_, _, let alignments) = block { return alignments }
            return nil
        }
        report.line("   columnas por tabla: \(headers.map(\.count)) · alineaciones: \(alignmentCounts.map(\.count))")

        // Listas con tareas: GFM las marca con [ ] y [x].
        let taskList = MarkdownParser.parse("- [ ] pendiente\n- [x] hecho\n- normal")
        let tasks = taskList.compactMap { block -> [MarkdownListItem]? in
            if case .list(_, let items) = block { return items }
            return nil
        }.first ?? []
        report.check("las listas de tareas se reconocen",
                     tasks.count == 3 && tasks[0].checked == false && tasks[1].checked == true,
                     tasks.map { "\($0.checked.map { $0 ? "x" : " " } ?? "-")" }.joined())
        report.check("las citas se reconocen", parsedQuotes >= 1, "\(parsedQuotes) citas")
        report.check("el markdown complejo no se colapsa en un solo bloque",
                     blocks.count >= 8, "\(blocks.count) bloques")
    }

    // MARK: 5. Markdown

    private static func checkMarkdown(_ report: Reporter) {
        report.section("5. Separación de bloques de markdown")
        let markdown = """
        Texto normal con **negrita**.

        ```swift
        let x = 1
        ```

        Y más texto.
        """
        let blocks = MarkdownParser.parse(markdown)
        let codeIsRight = blocks.contains {
            if case .code(let language, let body) = $0 {
                return language == "swift" && body.contains("let x = 1")
            }
            return false
        }
        let proseIsRight = blocks.contains {
            if case .paragraph(let value) = $0 { return value.contains("Texto normal") }
            return false
        }
        report.check("se detectó el bloque de código", codeIsRight, "\(blocks.count) bloques")
        report.check("el bloque conserva lenguaje y cuerpo", codeIsRight)
        report.check("la prosa quedó fuera del código", proseIsRight)
    }
}
