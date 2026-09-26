import Foundation
import P4WProc

// MARK: - Perfil de arranque

/// Un perfil es **un conjunto de argumentos de arranque de `pi`**. No hay nada especial en los
/// tres de fábrica: son puntos de partida (§6.1 del plan).
public struct ProfileSpec: Sendable, Equatable {
    /// Clave del perfil. Es lo que se guarda por conversación y por pestaña.
    public let name: String
    public let arguments: [String]
    public let note: String
    /// Etiqueta para mostrar. Se separa de `name` porque la clave tiene que ser estable y la etiqueta
    /// puede ser legible.
    public let label: String

    public init(name: String, arguments: [String], note: String, label: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.note = note
        self.label = label ?? name
    }

    /// Perfil liviano **más extensiones elegidas explícitamente**.
    ///
    /// Es la pieza clave del ahorro: `--no-extensions` apaga el descubrimiento (y con eso el costo de
    /// memoria y de arranque), pero **las rutas `-e` explícitas siguen cargando**. Así se puede tener
    /// un perfil de 122 MB que igual conserve el caché de prefijo —que es lo que hace que la entrada se
    /// pague cacheada en vez de completa (hasta 98 % más barata en DeepSeek)— y la navegación web.
    public static func lean(with extensions: [PiExtension], name: String, label: String) -> ProfileSpec {
        var arguments = lean.arguments
        for entry in extensions {
            for point in entry.entryPoints {
                arguments.append(contentsOf: ["-e", point])
            }
        }
        let included = extensions.map(\.shortName).joined(separator: ", ")
        return ProfileSpec(
            name: name,
            arguments: arguments,
            note: "Liviano, con \(included). El caché de prefijo abarata la entrada.",
            label: label
        )
    }

    /// Mínimo absoluto: sin extensiones, skills ni plantillas. Medido: 77 MB de footprint.
    public static let lean = ProfileSpec(
        name: "lean",
        arguments: ["--no-extensions", "--no-skills", "--no-prompt-templates"],
        note: "Sin extensiones ni skills. El más liviano y el que despierta más rápido."
    )

    /// Todo lo que la máquina tenga configurado. Medido: 325 MB de footprint, 5.4 s de arranque.
    public static let full = ProfileSpec(
        name: "full",
        arguments: [],
        note: "Todo lo configurado en Pi, tal como lo usa la TUI."
    )

    /// Conserva extensiones y skills, apaga los subsistemas que arrancan procesos hijos.
    public static let capabilities = ProfileSpec(
        name: "capabilities",
        arguments: ["--no-lens", "--no-lsp", "--no-tests", "--no-opengrep", "--no-autofix"],
        note: "Capacidades sin diagnósticos de código."
    )

    public static let builtIn: [ProfileSpec] = [.lean, .capabilities, .full]

    public static func named(_ name: String) -> ProfileSpec? {
        builtIn.first { $0.name == name }
    }
}

// MARK: - Modelo

/// Un modelo disponible según Pi. Se arma a partir del objeto `Model` que devuelve el protocolo;
/// P4W no mantiene su propia lista: pregunta y muestra lo que Pi tiene con credenciales usables.
public struct ModelOption: Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let name: String
    public let reasoning: Bool
    public let contextWindow: Int?

    public var key: String { "\(provider)/\(id)" }

    /// Etiqueta compacta para la barra: el nombre si lo hay, y el proveedor para desambiguar.
    public var shortLabel: String { name.isEmpty ? id : name }

    public init(id: String, provider: String, name: String,
                reasoning: Bool, contextWindow: Int?) {
        self.id = id
        self.provider = provider
        self.name = name
        self.reasoning = reasoning
        self.contextWindow = contextWindow
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.provider = json["provider"] as? String ?? ""
        self.name = json["name"] as? String ?? id
        self.reasoning = json["reasoning"] as? Bool ?? false
        self.contextWindow = json["contextWindow"] as? Int
    }
}

// MARK: - Estado

/// Estados de una instancia. `idle` / `working` / `blocked` usan el mismo vocabulario que herdr
/// para que el panel hable un solo idioma (§5.1 del plan).
public enum InstanceState: String, Sendable {
    case cold        // existe el registro, no hay proceso
    case starting    // proceso lanzado, esperando handshake
    case idle        // listo para recibir input
    case working     // hay un run activo
    case blocked     // hay un diálogo esperando respuesta
    case reaping     // apagándose para liberar memoria
    case failed      // el proceso murió o el handshake falló

    public var isBusy: Bool { self == .working || self == .blocked || self == .starting }
}

/// Por qué se liberó una instancia. Se registra para poder auditar que nunca se mató trabajo.
public enum ReapReason: String, Sendable {
    case idleTimeout = "idle_timeout"
    case capacity = "capacity_lru"
    case memoryPressure = "memory_pressure"
    case explicit = "explicit_request"
    case shutdown = "supervisor_shutdown"
}

// MARK: - Métricas de proceso

/// Envoltorio de `libproc`. `footprint` es lo que el proceso **posee**; `resident` incluye
/// páginas compartidas. La diferencia importa: medido en esta máquina, un `pi` lean tiene
/// RSS 120 MB pero footprint 77 MB, y las páginas compartidas no se pagan por instancia.
public struct ProcessMetrics: Sendable {
    /// Memoria propia del proceso, en bytes. `nil` si no se pudo leer.
    public static func footprint(pid: pid_t) -> Int64? {
        guard pid > 0 else { return nil }
        let value = p4w_phys_footprint(pid)
        return value > 0 ? value : nil
    }

    /// Memoria residente, en bytes (equivale a `ps rss`).
    public static func resident(pid: pid_t) -> Int64? {
        guard pid > 0 else { return nil }
        let value = p4w_resident_size(pid)
        return value > 0 ? value : nil
    }

    public static func descendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 1024)
        let count = p4w_list_descendants(pid, &buffer, 1024)
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// Termina el proceso y todo su árbol. Se enumeran los descendientes antes de señalar
    /// al padre: si el padre muere primero, los hijos quedan reparentados y se pierden.
    @discardableResult
    public static func terminateTree(pid: pid_t, signal: Int32 = SIGTERM) -> Int32 {
        guard pid > 0 else { return -1 }
        return p4w_terminate_tree(pid, signal)
    }

    public static func megabytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "n/d" }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Correlación de respuestas

/// El protocolo es asíncrono: no se puede asumir que la respuesta llega en orden.
/// Se correlaciona **por `id`**, siempre.
public final class PendingResponses: @unchecked Sendable {
    public struct Reply: @unchecked Sendable {
        public let command: String?
        public let success: Bool
        public let data: [String: Any]?
        public let error: String?
    }

    private let condition = NSCondition()
    private var replies: [String: Reply] = [:]

    public init() {}

    public func store(id: String?, command: String?, success: Bool,
                      data: [String: Any]?, error: String?) {
        guard let id else { return }
        condition.lock()
        replies[id] = Reply(command: command, success: success, data: data, error: error)
        condition.broadcast()
        condition.unlock()
    }

    public func await(id: String, timeout: TimeInterval) -> Reply? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while replies[id] == nil {
            if Date() >= deadline { return nil }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        return replies.removeValue(forKey: id)
    }
}

// MARK: - Instancia gestionada

/// Un `pi --mode rpc` bajo supervisión: sabe en qué estado está, cuándo fue su última
/// actividad, y si es seguro reciclarlo para liberar memoria.
public final class ManagedInstance: @unchecked Sendable {

    /// Clave del pool del supervisor. Es cómo P4W identifica la conversación **por dentro**
    /// (ruta del archivo, o `directorio#id` para una nueva). No es el id de Pi.
    public let poolKey: String

    /// Id de sesión **que reporta Pi** (`get_state.sessionId`). Es el que aparece en la cabecera
    /// del `.jsonl` y el que hay que usar para vincular con el catálogo. Se llena en el handshake.

    public let profile: ProfileSpec
    public let pi: PiInstance

    private let lock = NSRecursiveLock()
    private let responses = PendingResponses()
    private var requestCounter = 0

    private var _state: InstanceState = .cold
    private var _lastActivity = Date()
    private var _runActive = false
    private var _pendingDialogs = Set<String>()
    private var _usage = TokenUsage()
    /// Cantidad de mensajes **persistidos** en la rama activa. Es la cifra autoritativa:
    /// viene de `get_state`, no de contar eventos en vivo. El contador en vivo puede
    /// pasarse porque un mensaje con `stopReason: "pending"` no se persiste.
    private var _sessionID = ""
    /// Archivo de sesión que Pi tiene abierto, según `get_state`.
    private var _sessionFile: String?
    private var _persistedMessageCount = 0
    /// Contador provisional, útil solo para dar sensación de progreso durante un run.
    private var _liveMessageCount = 0
    private var _model: ModelOption?
    /// Nombre visible de la sesión, si Pi lo reportó.
    private var _sessionName: String?
    private var _thinkingLevel: String?
    private var _lastError: String?
    private var _lastStopReason: String?
    private var _lastRunErrored = false
    private var _reapCount = 0
    private var _creationCount = 0

    /// Texto y pensamiento del último mensaje del asistente, reconstruidos del stream.
    /// Reconstruir con deltas es válido para mostrar; `blockEnd` y `messageEnd` mandan.
    private var _liveText = ""
    private var _liveThinking = ""

    public var onEvent: ((PiEvent) -> Void)?
    public var onStateChange: ((InstanceState) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init(poolKey: String, profile: ProfileSpec, pi: PiInstance) {
        self.poolKey = poolKey
        self._sessionID = poolKey    // provisorio hasta el handshake
        self.profile = profile
        self.pi = pi
        pi.onRecord = { [weak self] record in self?.handle(record) }
        pi.onExit = { [weak self] status in
            guard let self else { return }
            self.lock.lock()
            // Si estábamos reciclando a propósito, la salida es esperada: va a `cold`, no a `failed`.
            let wasReaping = self._state == .reaping
            if !wasReaping { self._lastError = "el proceso salió con código \(status)" }
            self.transition(to: wasReaping ? .cold : .failed)
            self.lock.unlock()
            self.onExit?(status)
        }
    }

    // MARK: Lectura de estado

    public var state: InstanceState { lock.lock(); defer { lock.unlock() }; return _state }
    public var lastActivity: Date { lock.lock(); defer { lock.unlock() }; return _lastActivity }
    public var usage: TokenUsage { lock.lock(); defer { lock.unlock() }; return _usage }
    /// Mensajes persistidos en la sesión (autoritativo).
    public var messageCount: Int { lock.lock(); defer { lock.unlock() }; return _persistedMessageCount }
    /// Mensajes vistos en vivo durante este proceso. Puede superar al persistido.
    public var liveMessageCount: Int { lock.lock(); defer { lock.unlock() }; return _liveMessageCount }
    /// Motivo de parada del último mensaje del asistente (`stop`, `toolUse`, `error`…).
    public var lastStopReason: String? { lock.lock(); defer { lock.unlock() }; return _lastStopReason }
    /// `true` si la última corrida terminó en error. La UI **no** debe mostrarla como exitosa.
    public var lastRunErrored: Bool { lock.lock(); defer { lock.unlock() }; return _lastRunErrored }
    /// Id de sesión que reporta Pi. Una sola fuente: `_sessionID`, con lock como el resto.
    public var sessionID: String { lock.lock(); defer { lock.unlock() }; return _sessionID }

    public var modelID: String? { lock.lock(); defer { lock.unlock() }; return _model?.id }
    /// Modelo activo de esta conversación, tal como lo reporta Pi.
    public var currentModel: ModelOption? { lock.lock(); defer { lock.unlock() }; return _model }
    public var sessionName: String? { lock.lock(); defer { lock.unlock() }; return _sessionName }
    public var thinkingLevel: String? { lock.lock(); defer { lock.unlock() }; return _thinkingLevel }
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }
    public var reapCount: Int { lock.lock(); defer { lock.unlock() }; return _reapCount }
    public var liveText: String { lock.lock(); defer { lock.unlock() }; return _liveText }
    public var liveThinking: String { lock.lock(); defer { lock.unlock() }; return _liveThinking }
    public var pendingDialogCount: Int { lock.lock(); defer { lock.unlock() }; return _pendingDialogs.count }
    public var isRunActive: Bool { lock.lock(); defer { lock.unlock() }; return _runActive }

    public var pid: pid_t { pi.pid }
    public var isRunning: Bool { pi.running }

    /// Memoria propia del proceso, en bytes.
    public var footprintBytes: Int64? { ProcessMetrics.footprint(pid: pid) }
    public var residentBytes: Int64? { ProcessMetrics.resident(pid: pid) }

    public var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }

    /// Regla de oro 3 del plan: nunca reciclar algo ocupado. Esta es la única puerta.
    public var isReapable: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _state == .idle || _state == .failed else { return false }
        return !_runActive && _pendingDialogs.isEmpty
    }

    /// `true` solo si hay un proceso vivo al que se le puede hablar. Es la condición que
    /// `acquire` debe exigir para reutilizar en vez de lanzar de nuevo.
    public var isReusable: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _state != .cold, _state != .failed, _state != .reaping else { return false }
        return pi.running
    }

    // MARK: Ciclo de vida

    /// Lanza el proceso y hace el handshake. `wake` indica si es un despertar de una sesión
    /// que ya existía en disco (se relanza con `--session`), lo que recupera el contexto.
    /// `sessionArguments` viene de `SessionRef`: `--session <ruta>` para una conversación que ya
    /// existe, `--session-id <id>` para una nueva (que Pi crea si falta). No se reconstruye acá:
    /// fue justamente el error que impedía crear conversaciones nuevas.
    public func start(sessionArguments: [String], workingDirectory: URL?,
                      extraArguments: [String], handshakeTimeout: TimeInterval = 30) throws {
        lock.lock()
        transition(to: .starting)
        _lastError = nil
        _creationCount += 1
        lock.unlock()

        var arguments = profile.arguments + PiInstance.rpcMode + sessionArguments
        arguments.append(contentsOf: extraArguments)
        try pi.start(arguments: arguments, workingDirectory: workingDirectory)

        // Handshake: sin esto no sabemos modelo, nivel de thinking ni cantidad de mensajes.
        //
        // Se espera **vigilando el proceso**: si Pi se niega a arrancar (por ejemplo, porque la
        // carpeta guardada de la sesión ya no existe), muere al instante y su stderr trae el motivo.
        // Esperar el timeout completo y decir "sin respuesta" convertía un error claro en 30
        // segundos de silencio con un mensaje inútil.
        let stateResponse = requestCheckingLife(type: "get_state", timeout: handshakeTimeout)
        guard let stateResponse, stateResponse.success else {
            lock.lock()
            let reason = pi.stderrSummary
                ?? pi.exitStatus.map { "Pi terminó con código \($0)" }
                ?? "sin respuesta a get_state en \(Int(handshakeTimeout))s"
            _lastError = reason
            transition(to: .failed)
            lock.unlock()
            _ = pi.shutdown(timeout: 3)
            throw PiInstanceError.launchFailed(reason)
        }

        lock.lock()
        if let data = stateResponse.data {
            _persistedMessageCount = data["messageCount"] as? Int ?? 0
            _liveMessageCount = _persistedMessageCount
            _thinkingLevel = data["thinkingLevel"] as? String
            if let model = data["model"] as? [String: Any] { _model = ModelOption(json: model) }
            if let id = data["sessionId"] as? String, !id.isEmpty { _sessionID = id }
            _sessionFile = data["sessionFile"] as? String
            _sessionName = data["sessionName"] as? String
        }
        _lastActivity = Date()
        transition(to: .idle)
        lock.unlock()
    }

    /// Relee el estado autoritativo de Pi. Se llama cuando la instancia queda ociosa, para que
    /// `messageCount` refleje lo persistido y no lo contado en vivo. No se llama mientras
    /// corre: interrumpir el stream para preguntar sería contradictorio.
    public func refreshPersistedState() {
        let current = state
        guard current == .idle || current == .failed else { return }
        guard let reply = request(type: "get_state", timeout: 12), reply.success,
              let data = reply.data else { return }
        lock.lock()
        if let count = data["messageCount"] as? Int { _persistedMessageCount = count }
        if let level = data["thinkingLevel"] as? String { _thinkingLevel = level }
        if let id = data["sessionId"] as? String, !id.isEmpty { _sessionID = id }
        if let model = data["model"] as? [String: Any] { _model = ModelOption(json: model) }
        lock.unlock()
    }

    /// Como `request`, pero **corta antes si el proceso muere**. Se usa en el handshake, donde un
    /// proceso muerto es la respuesta y no vale la pena esperar el resto del tiempo.
    private func requestCheckingLife(type: String, timeout: TimeInterval) -> PendingResponses.Reply? {
        lock.lock()
        requestCounter += 1
        let id = "p4w-\(requestCounter)"
        lock.unlock()
        do {
            try pi.send(id: id, type: type)
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = responses.await(id: id, timeout: 0.2) { return reply }
            if !pi.running { return nil }
        }
        return nil
    }

    @discardableResult
    public func request(type: String, fields: [String: Any] = [:],
                        timeout: TimeInterval = 20) -> PendingResponses.Reply? {
        lock.lock()
        requestCounter += 1
        let id = "p4w-\(requestCounter)"
        lock.unlock()
        do {
            try pi.send(id: id, type: type, fields: fields)
        } catch {
            return nil
        }
        return responses.await(id: id, timeout: timeout)
    }

    /// Cómo se entrega un mensaje enviado mientras Pi trabaja. Espeja el estándar de Pi:
    /// `Enter` encola una guía, `Alt+Enter` un seguimiento.
    public enum SendMode: Sendable {
        case now          // Pi está libre: se envía directo
        case steer        // guía: se entrega después del turno actual y sus herramientas
        case followUp     // seguimiento: se entrega cuando Pi termina todo

        /// Público a propósito: es el contrato con Pi y conviene poder verificarlo.
        public var streamingBehavior: String? {
            switch self {
            case .now: return nil
            case .steer: return "steer"
            case .followUp: return "followUp"
            }
        }
    }

    /// Envía eligiendo el modo según el estado real del proceso. Si Pi está trabajando y se manda
    /// sin `streamingBehavior`, el protocolo **rechaza** el mensaje: por eso la decisión no puede
    /// quedar del lado de la UI.
    public func send(_ text: String, images: [[String: Any]] = [],
                     requested: SendMode = .now) throws {
        let mode: SendMode = (requested == .now && state.isBusy) ? .steer : requested
        try sendPrompt(text, images: images, streamingBehavior: mode.streamingBehavior)
    }

    /// ¿Hay un turno en curso? Es lo que decide si un mensaje nuevo se encola.
    public var isWorking: Bool { state.isBusy || isRunActive }

    /// Saca los mensajes en cola y los devuelve, para restaurarlos en el editor.
    /// Es el "dequeue" de Pi (`Alt+Up`): primero se saca de la cola, después se aborta si hace falta.
    public func clearQueue() -> (steering: [String], followUp: [String]) {
        guard let reply = request(type: "clear_queue", timeout: 15), reply.success else {
            return ([], [])
        }
        let steering = reply.data?["steering"] as? [String] ?? []
        let followUp = reply.data?["followUp"] as? [String] ?? []
        return (steering, followUp)
    }

    public func sendPrompt(_ text: String, images: [[String: Any]] = [],
                           streamingBehavior: String? = nil) throws {
        lock.lock()
        requestCounter += 1
        let id = "p4w-\(requestCounter)"
        _lastActivity = Date()
        lock.unlock()
        try pi.send(RPCCommand.prompt(id: id, message: text, images: images,
                                      streamingBehavior: streamingBehavior))
    }

    public func abort() {
        _ = request(type: "abort", timeout: 10)
    }

    /// Apagado ordenado: cerrar stdin es la señal correcta, `terminate` es el último recurso.
    /// Se enumeran los descendientes antes por si el apagado ordenado no alcanza.
    public func beginReap(reason: ReapReason, gracefulTimeout: TimeInterval = 6) -> ReapOutcome {
        lock.lock()
        transition(to: .reaping)
        let children = ProcessMetrics.descendants(of: pid)
        lock.unlock()

        let before = footprintBytes
        let status = pi.shutdown(timeout: gracefulTimeout)

        var forced = false
        if status == nil, pi.running {
            ProcessMetrics.terminateTree(pid: pid)
            forced = true
            usleep(300_000)
        }

        lock.lock()
        _reapCount += 1
        _runActive = false
        _pendingDialogs.removeAll()
        transition(to: .cold)
        lock.unlock()

        return ReapOutcome(reason: reason, exitStatus: status, forced: forced,
                           descendantsFound: children.count, footprintFreedBytes: before)
    }

    // MARK: Modelo y thinking (siempre por RPC, nunca tocando archivos)

    /// Modelos que Pi tiene configurados y con credenciales usables.
    /// Es la misma lista que ofrece el selector `/model` de la terminal.
    public func availableModels() -> [ModelOption] {
        guard let reply = request(type: "get_available_models", timeout: 25), reply.success,
              let raw = reply.data?["models"] as? [[String: Any]] else { return [] }
        return raw.compactMap(ModelOption.init(json:)).sorted {
            ($0.provider, $0.shortLabel) < ($1.provider, $1.shortLabel)
        }
    }

    /// Niveles de thinking **soportados por el modelo activo**. Depende del modelo: con uno sin
    /// razonamiento Pi devuelve solo `off`. La UI los genera, no los asume.
    public func availableThinkingLevels() -> [String] {
        guard let reply = request(type: "get_available_thinking_levels", timeout: 20),
              reply.success, let levels = reply.data?["levels"] as? [String] else { return [] }
        return levels
    }

    /// Cambia el modelo de **esta conversación**. Pi lo registra en la sesión (`model_change`),
    /// así que reabrirla lo restaura; el predeterminado de Pi no se toca.
    @discardableResult
    public func setModel(_ option: ModelOption) -> ModelOption? {
        guard let reply = request(type: "set_model", fields: [
            "provider": option.provider,
            "modelId": option.id,
        ], timeout: 30) else { return nil }

        guard reply.success else {
            lock.lock()
            _lastError = reply.error ?? "no se pudo cambiar el modelo"
            lock.unlock()
            return nil
        }
        lock.lock()
        // La respuesta trae el modelo aplicado; si viene vacía se usa el pedido.
        _model = reply.data.flatMap(ModelOption.init(json:)) ?? option
        // Los niveles de thinking dependen del modelo: hay que releerlos.
        _lastError = nil
        lock.unlock()
        if let levels = availableThinkingLevels().first {
            lock.lock(); _thinkingLevel = levels; lock.unlock()
        }
        return currentModel
    }

    @discardableResult
    public func setThinkingLevel(_ level: String) -> Bool {
        guard let reply = request(type: "set_thinking_level", fields: ["level": level], timeout: 20)
        else { return false }
        guard reply.success else {
            lock.lock()
            _lastError = reply.error ?? "no se pudo cambiar el nivel de thinking"
            lock.unlock()
            return false
        }
        lock.lock()
        _thinkingLevel = level
        lock.unlock()
        return true
    }

    // MARK: Acciones sobre la conversación (todas por RPC, nunca tocando el archivo)

    /// Un mensaje del usuario desde el que se puede bifurcar.
    public struct ForkCandidate: Sendable, Identifiable {
        public let entryId: String
        public let text: String
        public var id: String { entryId }

        public var label: String {
            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return clean.count > 70 ? String(clean.prefix(70)) + "…" : clean
        }
    }

    /// Archivo de sesión que Pi tiene abierto. Cambia después de un `fork`.
    public var sessionFile: String? {
        lock.lock(); defer { lock.unlock() }
        return _sessionFile
    }

    /// Pone un nombre visible. Aparece en los listados de Pi, así que es la misma operación que su
    /// `/name`: no se escribe el `.jsonl` a mano (invariante 1).
    @discardableResult
    public func rename(to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = request(type: "set_session_name", fields: ["name": trimmed], timeout: 15)
        guard let reply, reply.success else {
            lock.lock()
            _lastError = reply?.error ?? "no se pudo renombrar"
            lock.unlock()
            return false
        }
        lock.lock()
        _sessionName = trimmed.isEmpty ? nil : trimmed
        lock.unlock()
        return true
    }

    /// Mensajes desde los que se puede bifurcar en la rama activa.
    public func forkCandidates() -> [ForkCandidate] {
        guard let reply = request(type: "get_fork_messages", timeout: 20), reply.success,
              let raw = reply.data?["messages"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let id = item["entryId"] as? String else { return nil }
            return ForkCandidate(entryId: id, text: item["text"] as? String ?? "")
        }
    }

    /// Bifurca desde un mensaje. Devuelve el archivo de la sesión nueva, que es lo que hay que
    /// seleccionar después: Pi **cambia de sesión** en el mismo proceso.
    public func fork(from entryId: String) -> String? {
        let reply = request(type: "fork", fields: ["entryId": entryId], timeout: 30)
        guard let reply, reply.success else {
            lock.lock()
            _lastError = reply?.error ?? "no se pudo bifurcar"
            lock.unlock()
            return nil
        }
        if reply.data?["cancelled"] as? Bool == true {
            lock.lock()
            _lastError = "una extensión canceló la bifurcación"
            lock.unlock()
            return nil
        }
        // La sesión nueva se consulta al estado: la respuesta de `fork` no trae la ruta.
        guard let state = request(type: "get_state", timeout: 20), state.success else { return nil }
        let file = state.data?["sessionFile"] as? String
        lock.lock()
        _sessionFile = file
        if let id = state.data?["sessionId"] as? String, !id.isEmpty { _sessionID = id }
        _persistedMessageCount = state.data?["messageCount"] as? Int ?? _persistedMessageCount
        lock.unlock()
        return file
    }

    /// Exporta a HTML. Se le pasa la ruta para que el resultado sea predecible y P4W sepa qué abrir.
    @discardableResult
    public func exportHTML(to outputPath: String) -> URL? {
        let reply = request(type: "export_html", fields: ["outputPath": outputPath], timeout: 60)
        guard let reply, reply.success, let path = reply.data?["path"] as? String else {
            lock.lock()
            _lastError = reply?.error ?? "no se pudo exportar"
            lock.unlock()
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: Eventos

    private func handle(_ record: RPCRecord) {
        switch record {
        case .response(let id, let command, let success, let data, let error):
            responses.store(id: id, command: command, success: success, data: data, error: error)

        case .unparseable(let raw):
            lock.lock()
            _lastError = "registro no parseable: \(raw.prefix(120))"
            lock.unlock()

        case .event(_, let payload):
            let event = PiEvent.decode(payload)
            apply(event)
            onEvent?(event)
        }
    }

    /// Máquina de estados derivada del stream. Acá no se adivina nada: se reacciona a eventos.
    public func apply(_ event: PiEvent) {
        lock.lock()
        defer { lock.unlock() }
        _lastActivity = Date()

        switch event {
        case .messageStart(let role): applyMessageStart(role)
        case .delta(let delta, let usage): applyDelta(delta, usage: usage)
        case .blockEnd(let block): applyBlockEnd(block)
        case .messageEnd(let role, let text, let thinking, let stopReason, let error, let usage):
            applyMessageEnd(role: role, text: text, thinking: thinking,
                            stopReason: stopReason, error: error, usage: usage)
        case .agentStart: applyAgentStart()
        case .agentSettled: applyAgentSettled()
        case .uiDialog(let dialog): applyDialogOpened(dialog)
        case .uiDialogResolved(let id): applyDialogClosed(id)
        case .thinkingLevelChanged(let level): _thinkingLevel = level
        case .sessionInfoChanged(let name): _sessionName = name
        case .compactionStart: applyCompactionStart()
        case .compactionEnd(let reason, let aborted, let error, let willRetry, _, _):
            applyCompactionEnd(reason: reason, aborted: aborted, error: error, willRetry: willRetry)
        case .retryStarted(let attempt, let maxAttempts, let error):
            applyRetryStarted(attempt: attempt, maxAttempts: maxAttempts, error: error)
        case .retryFinished(let success, let finalError):
            applyRetryFinished(success: success, finalError: finalError)
        case .extensionError(let message):
            _lastError = "extensión: \(message)"
        case .agentEnd, .uiNotice, .toolExecutionStart, .toolExecutionUpdate, .toolExecutionEnd,
             .turnStart, .turnEnd, .queueChanged, .bashExecutionOutput,
             .toolCallStarted, .toolCallArguments, .toolCallCompleted, .toolInput, .other:
            break
        }
    }

    private func applyMessageStart(_ role: String?) {
        guard role == "assistant" else { return }
        _liveText = ""
        _liveThinking = ""
    }

    private func applyDelta(_ delta: ContentDelta, usage: TokenUsage?) {
        if let usage { _usage = usage }
        switch delta.kind {
        case .text: _liveText += delta.text
        case .thinking: _liveThinking += delta.text
        case .toolCallArguments: break
        }
    }

    /// El contenido autoritativo reemplaza lo reconstruido con deltas.
    private func applyBlockEnd(_ block: ContentBlockEnd) {
        switch block.kind {
        case .text: _liveText = block.text
        case .thinking: _liveThinking = block.text
        }
    }

    private func applyMessageEnd(role: String?, text: String, thinking: String,
                                stopReason: String?, error: String?, usage: TokenUsage?) {
        if let usage { _usage = usage }
        _lastStopReason = stopReason
        if stopReason == "error" {
            // Una corrida que falla no puede reportarse como exitosa. Esto lo vio Fase 1
            // cuando el proveedor agotó reintentos y el estado igual caía en `idle`.
            _lastRunErrored = true
            _lastError = error ?? "el proveedor devolvió un error"
        } else if stopReason != nil {
            _lastRunErrored = false
        }
        guard role == "assistant" else { return }
        if !text.isEmpty { _liveText = text }
        if !thinking.isEmpty { _liveThinking = thinking }
        _liveMessageCount += 1
    }

    private func applyAgentStart() {
        _runActive = true
        guard _pendingDialogs.isEmpty else { return }
        transition(to: .working)
    }

    /// `agent_settled` es la señal real de "terminó": no queda trabajo automático pendiente.
    /// (`agent_end` cierra un run de bajo nivel y puede seguir retry o compactación.)
    private func applyAgentSettled() {
        _runActive = false
        transition(to: _pendingDialogs.isEmpty ? .idle : .blocked)
    }

    private func applyDialogOpened(_ dialog: DialogRequest) {
        _pendingDialogs.insert(dialog.id)
        transition(to: .blocked)
    }

    /// Responde un diálogo de extensión. `value` para select/input/editor, `confirmed` para
    /// confirm, o `cancelled`. Los nombres de campo son los que Pi espera.
    public func respond(dialog id: String, value: String? = nil,
                        confirmed: Bool? = nil, cancelled: Bool = false) throws {
        var fields: [String: Any] = ["id": id]
        if cancelled {
            fields["cancelled"] = true
        } else if let confirmed {
            fields["confirmed"] = confirmed
        } else if let value {
            fields["value"] = value
        } else {
            fields["cancelled"] = true
        }
        try pi.send(RPCCommand.encode(id: nil, type: "extension_ui_response", fields: fields))
        apply(.uiDialogResolved(id: id))
    }

    private func applyDialogClosed(_ id: String) {
        _pendingDialogs.remove(id)
        guard _pendingDialogs.isEmpty else { return }
        transition(to: _runActive ? .working : .idle)
    }

    private func applyCompactionStart() {
        transition(to: .working)
    }

    private func applyCompactionEnd(reason: String?, aborted: Bool, error: String?, willRetry: Bool) {
        if let error {
            _lastError = "compactación falló (\(reason ?? "?")): \(error)"
        } else if aborted {
            _lastError = "compactación cancelada (\(reason ?? "?"))"
        }
        guard _pendingDialogs.isEmpty else { return }
        transition(to: willRetry ? .working : (_runActive ? .working : .idle))
    }

    /// Un reintento es **trabajo en curso**, no un final: el estado sigue en `working`.
    private func applyRetryStarted(attempt: Int, maxAttempts: Int, error: String) {
        _lastError = "reintento \(attempt)/\(maxAttempts): \(error)"
        transition(to: .working)
    }

    private func applyRetryFinished(success: Bool, finalError: String?) {
        guard !success else { return }
        _lastRunErrored = true
        _lastError = finalError ?? _lastError ?? "se agotaron los reintentos"
    }

    /// El caller confirma que respondió a un diálogo (la UI envía `extension_ui_response`).
    public func markDialogResolved(id: String) {
        apply(.uiDialogResolved(id: id))
    }

    private func transition(to newState: InstanceState) {
        guard _state != newState else { return }
        _state = newState
        onStateChange?(newState)
    }
}

/// Resultado de un reciclado. Se devuelve en vez de registrarse en un log para que el
/// supervisor pueda mostrar y auditar qué se liberó y por qué.
public struct ReapOutcome: Sendable {
    public let reason: ReapReason
    public let exitStatus: Int32?
    public let forced: Bool
    public let descendantsFound: Int
    public let footprintFreedBytes: Int64?

    public var summary: String {
        let how = forced ? "forzado" : (exitStatus.map { "rc \($0)" } ?? "sin salida")
        return "\(reason.rawValue): \(how), hijos \(descendantsFound), liberó \(ProcessMetrics.megabytes(footprintFreedBytes))"
    }
}
