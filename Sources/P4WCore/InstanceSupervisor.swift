import Foundation

/// Cómo se identifica una conversación al lanzar `pi`.
public enum SessionRef: Sendable {
    /// Sesión que ya existe en disco: se relanza con `--session <ruta>`, lo que recupera el contexto.
    case existing(path: String)
    /// Sesión nueva: se crea con `--session-id`, opcionalmente en un directorio propio.
    case new(id: String, directory: String?)

    public var key: String {
        switch self {
        case .existing(let path): return path
        case .new(let id, let directory): return "\(directory ?? "")#\(id)"
        }
    }

    /// Flags que se le pasan a Pi. Público a propósito: es la pieza que se rompió una vez
    /// (`--session` vs `--session-id`) y conviene poder verificarla.
    public var arguments: [String] {
        switch self {
        case .existing(let path):
            return ["--session", path]
        case .new(let id, let directory):
            var args = ["--session-id", id]
            if let directory { args.append(contentsOf: ["--session-dir", directory]) }
            return args
        }
    }
}

public struct SupervisorConfig: Sendable {
    public var piExecutable: URL
    public var defaultProfile: ProfileSpec
    /// Segundos de inactividad antes de liberar. Configurable a propósito (§6.1).
    public var reapAfterSeconds: TimeInterval
    /// Tope de instancias vivas. Al superarlo se recicla el idle más viejo.
    public var maxLiveInstances: Int
    /// Bajo presión de memoria de macOS se recicla agresivo, pero nunca algo ocupado.
    public var reapOnMemoryPressure: Bool
    /// Directorio de trabajo de las instancias.
    ///
    /// **Nunca puede quedar en nil.** Sin esto, una app lanzada desde Finder hereda `/` como
    /// directorio y Pi agrupa esas conversaciones en `----` (la raíz): las herramientas corren
    /// donde no están los archivos del usuario y las sesiones quedan en una carpeta que no existe.
    public var workingDirectory: URL?
    public var extraArguments: [String]
    public var tickInterval: TimeInterval

    public init(
        piExecutable: URL,
        defaultProfile: ProfileSpec = .lean,
        reapAfterSeconds: TimeInterval = 30,
        maxLiveInstances: Int = 3,
        reapOnMemoryPressure: Bool = true,
        workingDirectory: URL? = nil,
        extraArguments: [String] = [],
        tickInterval: TimeInterval = 1
    ) {
        self.piExecutable = piExecutable
        self.defaultProfile = defaultProfile
        self.reapAfterSeconds = reapAfterSeconds
        self.maxLiveInstances = maxLiveInstances
        self.reapOnMemoryPressure = reapOnMemoryPressure
        self.workingDirectory = workingDirectory
        self.extraArguments = extraArguments
        self.tickInterval = tickInterval
    }
}

/// Foto del estado del pool, para el panel de agentes.
public struct InstanceSummary: Sendable {
    public let sessionKey: String
    public let sessionID: String
    public let profileName: String
    public let state: InstanceState
    public let pid: pid_t
    public let footprintBytes: Int64?
    public let residentBytes: Int64?
    public let idleSeconds: TimeInterval
    public let messageCount: Int
    public let liveMessageCount: Int
    public let lastRunErrored: Bool
    public let lastError: String?
    public let modelID: String?
    public let thinkingLevel: String?
    public let usage: TokenUsage
    public let reapable: Bool
    public let runActive: Bool
    public let pendingDialogs: Int
    public let reapCount: Int

    /// Público a propósito: el panel y las verificaciones construyen fotos con estados armados a mano
    /// (por ejemplo, para comprobar el orden por atención sin depender de que algo se bloquee de verdad).
    public init(sessionKey: String, sessionID: String, profileName: String, state: InstanceState,
                pid: pid_t, footprintBytes: Int64?, residentBytes: Int64?, idleSeconds: TimeInterval,
                messageCount: Int, liveMessageCount: Int, lastRunErrored: Bool, lastError: String?,
                modelID: String?, thinkingLevel: String?, usage: TokenUsage, reapable: Bool,
                runActive: Bool, pendingDialogs: Int, reapCount: Int) {
        self.sessionKey = sessionKey
        self.sessionID = sessionID
        self.profileName = profileName
        self.state = state
        self.pid = pid
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.idleSeconds = idleSeconds
        self.messageCount = messageCount
        self.liveMessageCount = liveMessageCount
        self.lastRunErrored = lastRunErrored
        self.lastError = lastError
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
        self.usage = usage
        self.reapable = reapable
        self.runActive = runActive
        self.pendingDialogs = pendingDialogs
        self.reapCount = reapCount
    }

    /// ¿Cambió algo que la **interfaz muestre**?
    ///
    /// Publicar de nuevo el mismo estado hace que SwiftUI vuelva a dibujar todo lo que lo observa: la
    /// investigación es clara en que asignar `@Published` cada segundo dispara re-renders aunque el
    /// valor sea equivalente. Por eso se comparan solo los campos visibles, y los que cambian solos
    /// (tiempo ocioso, bytes) se comparan **en cubetas**: el panel muestra "idle 10s" y "78 MB", no
    /// "10,37 s" ni "81.855.448 bytes".
    public func differsVisibly(from other: InstanceSummary) -> Bool {
        if state != other.state || pid != other.pid || reapable != other.reapable { return true }
        if messageCount != other.messageCount || pendingDialogs != other.pendingDialogs { return true }
        if reapCount != other.reapCount || profileName != other.profileName { return true }
        if sessionID != other.sessionID || (modelID ?? "") != (other.modelID ?? "") { return true }
        if Int(idleSeconds / 5) != Int(other.idleSeconds / 5) { return true }
        // Los bytes se comparan por decenas de MB: un cambio de 1 MB no cambia lo que se lee.
        let mine = (footprintBytes ?? 0) / (10 * 1_048_576)
        let theirs = (other.footprintBytes ?? 0) / (10 * 1_048_576)
        return mine != theirs
    }

    public var line: String {
        let idle = String(format: "%.0fs", idleSeconds)
        let flag = reapable ? "reciclable" : "en uso"
        return "\(state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) "
            + "\(profileName.padding(toLength: 12, withPad: " ", startingAt: 0)) "
            + "pid \(String(pid).padding(toLength: 6, withPad: " ", startingAt: 0)) "
            + "propio \(ProcessMetrics.megabytes(footprintBytes).padding(toLength: 8, withPad: " ", startingAt: 0)) "
            + "resid \(ProcessMetrics.megabytes(residentBytes).padding(toLength: 8, withPad: " ", startingAt: 0)) "
            + "idle \(idle.padding(toLength: 6, withPad: " ", startingAt: 0)) "
            + "msgs \(String(messageCount).padding(toLength: 4, withPad: " ", startingAt: 0)) \(flag)"
    }
}

/// Registro auditable de cada reciclado. Existe para poder probar que nunca se mató trabajo.
public struct ReapRecord: Sendable {
    public let date: Date
    public let sessionKey: String
    public let outcome: ReapOutcome
}

/// El supervisor del pool. Es la pieza que hace cumplir el requisito central: **solo las
/// conversaciones en uso tienen un proceso vivo, y lo que se deja de usar libera memoria.**
public final class InstanceSupervisor: @unchecked Sendable {

    public let config: SupervisorConfig
    private let environment: ShellEnvironment
    private let lock = NSRecursiveLock()
    private var instances: [String: ManagedInstance] = [:]
    private var audits: [ReapRecord] = []
    /// Conversaciones **ancladas**: nunca se reciclan, por más ociosas que parezcan.
    ///
    /// Es la red de seguridad contra el bug más caro posible: el usuario escribiendo un mensaje
    /// largo no genera eventos, así que el reaper la veía "ociosa" y la apagaba en la cara.
    private var pinnedKeys: Set<String> = []
    private let auditLimit = 200

    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "p4w.supervisor", qos: .utility)

    /// Se dispara cuando el pool cambia, con la foto completa.
    public var onSnapshot: (([InstanceSummary]) -> Void)?
    /// Se dispara al liberar una instancia.
    public var onReap: ((String, ReapOutcome) -> Void)?
    /// Se dispara cuando una instancia cambia de estado.
    public var onInstanceStateChange: ((String, InstanceState) -> Void)?

    public init(config: SupervisorConfig, environment: ShellEnvironment) {
        self.config = config
        self.environment = environment
    }

    deinit { stop() }

    // MARK: Arranque

    public func start() {
        lock.lock()
        let alreadyStarted = timer != nil
        if !alreadyStarted {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + config.tickInterval, repeating: config.tickInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()

            if config.reapOnMemoryPressure {
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical], queue: queue
                )
                source.setEventHandler { [weak self] in self?.handleMemoryPressure() }
                pressureSource = source
                source.resume()
            }
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        lock.unlock()
    }

    // MARK: API del pool

    /// Devuelve una instancia lista para usar. Si ya hay una viva para esa sesión, la reutiliza
    /// (despertar). Si no, la lanza. Nunca hay dos procesos sobre la misma sesión (regla de oro 2).
    ///
    /// Solo se reutiliza si el proceso **está vivo de verdad**. Una entrada en `cold` o `failed`
    /// es un fantasma de contabilidad: devolverla entregaría una instancia muerta.
    @discardableResult
    public func acquire(_ session: SessionRef,
                        profile: ProfileSpec? = nil,
                        workingDirectory: URL? = nil) throws -> ManagedInstance {
        let key = session.key
        let chosen = profile ?? config.defaultProfile

        if let existing = liveInstance(for: key), existing.isReusable {
            return existing
        }

        lock.lock()
        instances.removeValue(forKey: key)
        lock.unlock()

        let instance = ManagedInstance(
            poolKey: key,
            profile: chosen,
            pi: PiInstance(executable: config.piExecutable, environment: environment)
        )
        instance.onStateChange = { [weak self, weak instance] state in
            self?.onInstanceStateChange?(key, state)
            if state == .idle {
                // Al quedar ociosa, se relee el conteo persistido: el contador en vivo puede
                // haberse pasado. Se hace async para no retener el lock durante un RPC.
                self?.queue.async { instance?.refreshPersistedState() }
            }
            self?.publish()
        }

        try instance.start(
            sessionArguments: session.arguments,
            workingDirectory: workingDirectory ?? config.workingDirectory ?? Self.homeDirectory,
            extraArguments: config.extraArguments
        )

        lock.lock()
        instances[key] = instance
        lock.unlock()

        publish()
        enforceCapacity()
        return instance
    }

    /// Ancla conversaciones para que sean intocables: el reciclador no las toca, ni por tiempo ni por
    /// tope ni por presión de memoria.
    ///
    /// Es un conjunto y no una sola: la conversación visible se ancla siempre, y además la persona
    /// puede fijar otras (por ejemplo, una que está esperando una respuesta larga en segundo plano).
    public func setPinned(_ keys: Set<String>) {
        lock.lock()
        pinnedKeys = keys
        lock.unlock()
    }

    /// Atajo para anclar una sola. Pasar `nil` las suelta a todas.
    public func pin(_ key: String?) {
        setPinned(key.map { [$0] } ?? [])
    }

    public var pinned: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return pinnedKeys
    }

    public func isPinned(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pinnedKeys.contains(key)
    }

    /// Directorio del usuario. Es el piso: si nadie especifica nada, se trabaja acá y no en `/`.
    public static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public func liveInstance(for key: String) -> ManagedInstance? {
        lock.lock(); defer { lock.unlock() }
        return instances[key]
    }

    public func allInstances() -> [ManagedInstance] {
        lock.lock(); defer { lock.unlock() }
        return Array(instances.values)
    }

    /// Libera una sesión explícitamente (por ejemplo, al cerrar su ventana).
    @discardableResult
    public func release(_ key: String, reason: ReapReason = .explicit) -> ReapOutcome? {
        guard let instance = liveInstance(for: key) else { return nil }
        return performReap(instance, key: key, reason: reason)
    }

    // MARK: Reciclado

    /// Recicla lo que está inactivo más allá del umbral. **Solo** lo intacto: la regla es que
    /// un run activo, un diálogo pendiente o cualquier estado ocupado no se toca jamás.
    @discardableResult
    public func reapIdle(now: Date = Date(), threshold: TimeInterval? = nil) -> [String] {
        let limit = threshold ?? config.reapAfterSeconds
        var reaped: [String] = []
        for (key, instance) in snapshotOfPool() {
            guard !isPinned(key) else { continue }
            guard instance.isReapable else { continue }
            guard instance.idleSeconds >= limit else { continue }
            if performReap(instance, key: key, reason: .idleTimeout) != nil { reaped.append(key) }
        }
        return reaped
    }

    /// Al superar el tope se recicla el idle más viejo. Si no hay ninguno reciclable **no se mata
    /// nada**: se prefiere exceder el tope antes que interrumpir trabajo (regla de oro 3).
    @discardableResult
    public func enforceCapacity() -> [String] {
        var reaped: [String] = []
        while true {
            let pool = snapshotOfPool()
            guard pool.count > config.maxLiveInstances else { break }
            let candidates = pool.filter { !isPinned($0.0) && $0.1.isReapable }
            guard let victim = candidates.max(by: { $0.1.idleSeconds < $1.1.idleSeconds }) else { break }
            if performReap(victim.1, key: victim.0, reason: .capacity) != nil {
                reaped.append(victim.0)
            } else {
                break
            }
        }
        return reaped
    }

    private func handleMemoryPressure() {
        // Presión de memoria: se recicla todo lo intacto, sin esperar el umbral de tiempo.
        reapIdle(now: Date(), threshold: 1)
    }

    private func tick() {
        _ = pruneDeadEntries()
        _ = reapIdle()
        _ = enforceCapacity()
        publish()
    }

    /// Saca del pool las entradas cuyo proceso ya no existe. Sin esto quedan filas fantasma
    /// en el panel (con un pid muerto) y `acquire` podría devolver una instancia inservible.
    @discardableResult
    private func pruneDeadEntries() -> [String] {
        lock.lock()
        let dead = instances.filter { !$0.value.isReusable }
        for key in dead.keys { instances.removeValue(forKey: key) }
        lock.unlock()
        if !dead.isEmpty { publish() }
        return Array(dead.keys)
    }

    /// Hace el reciclado **sin tener el lock del supervisor**: `beginReap` puede bloquear hasta
    /// varios segundos esperando el apagado ordenado, y bloquear el pool en ese lapso congelaría
    /// al resto de las instancias.
    @discardableResult
    private func performReap(_ instance: ManagedInstance, key: String, reason: ReapReason) -> ReapOutcome? {
        guard instance.isReapable else { return nil }
        // Defensa en profundidad: ni por un camino inesperado se apaga lo que el usuario está viendo.
        guard reason == .shutdown || reason == .explicit || !isPinned(key) else { return nil }
        let outcome = instance.beginReap(reason: reason)
        lock.lock()
        if instances[key] === instance { instances.removeValue(forKey: key) }
        audits.append(ReapRecord(date: Date(), sessionKey: key, outcome: outcome))
        if audits.count > auditLimit { audits.removeFirst(audits.count - auditLimit) }
        lock.unlock()
        onReap?(key, outcome)
        publish()
        return outcome
    }

    /// Apaga todo respetando el orden: primero stdin, después el árbol si no alcanza.
    public func shutdownAll() {
        for (key, instance) in snapshotOfPool() {
            if instance.isReapable {
                _ = performReap(instance, key: key, reason: .shutdown)
            } else {
                // Ocupada: se pide abort y se espera un poco antes de forzar.
                instance.abort()
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline && !instance.isReapable { usleep(100_000) }
                _ = performReap(instance, key: key, reason: .shutdown)
            }
        }
    }

    // MARK: Lectura

    public func snapshot() -> [InstanceSummary] {
        snapshotOfPool()
            .map { summary(for: $0.key, instance: $0.value) }
            .sorted { $0.idleSeconds > $1.idleSeconds }
    }

    public var auditLog: [ReapRecord] {
        lock.lock(); defer { lock.unlock() }
        return audits
    }

    /// Memoria total que P4W está consumiendo por sus instancias: **propia** (footprint) y
    /// residente. La propia es la que se libera al reciclar; la residente incluye páginas
    /// compartidas que no se pagan por instancia.
    public func totalMemory() -> (footprint: Int64, resident: Int64) {
        var footprint: Int64 = 0
        var resident: Int64 = 0
        for (_, instance) in snapshotOfPool() {
            footprint += instance.footprintBytes ?? 0
            resident += instance.residentBytes ?? 0
        }
        return (footprint, resident)
    }

    private func snapshotOfPool() -> [(key: String, value: ManagedInstance)] {
        lock.lock(); defer { lock.unlock() }
        return instances.map { ($0.key, $0.value) }
    }

    private func summary(for key: String, instance: ManagedInstance) -> InstanceSummary {
        InstanceSummary(
            sessionKey: key,
            sessionID: instance.sessionID,
            profileName: instance.profile.name,
            state: instance.state,
            pid: instance.pid,
            footprintBytes: instance.footprintBytes,
            residentBytes: instance.residentBytes,
            idleSeconds: instance.idleSeconds,
            messageCount: instance.messageCount,
            liveMessageCount: instance.liveMessageCount,
            lastRunErrored: instance.lastRunErrored,
            lastError: instance.lastError,
            modelID: instance.modelID,
            thinkingLevel: instance.thinkingLevel,
            usage: instance.usage,
            reapable: instance.isReapable,
            runActive: instance.isRunActive,
            pendingDialogs: instance.pendingDialogCount,
            reapCount: instance.reapCount
        )
    }

    private var lastPublished: [InstanceSummary] = []

    /// Solo avisa si **algo visible cambió**. Es la diferencia entre un panel que se redibuja una vez
    /// por segundo sin motivo y uno que se redibuja cuando pasa algo.
    private func publish() {
        guard let onSnapshot else { return }
        let current = snapshot()
        let same = current.count == lastPublished.count
            && zip(current, lastPublished).allSatisfy { !$0.differsVisibly(from: $1) }
        guard !same else { return }
        lastPublished = current
        onSnapshot(current)
    }

}
