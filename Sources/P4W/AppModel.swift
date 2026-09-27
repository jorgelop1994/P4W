import AppKit
import SwiftUI
import UserNotifications
import P4WCore

/// Estado de la aplicación. Es el único punto donde la UI habla con el núcleo.
@MainActor
final class AppModel: ObservableObject {

    // Sesiones
    @Published var sessions: [SessionSummary] = []
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchHits: [SessionIndex.SearchHit] = []
    @Published var isSearching = false
    private var searchTask: Task<Void, Never>?
    @Published var current: SessionSummary?
    @Published var isLoadingHistory = false
    /// Si quedan mensajes más viejos por cargar (la conversación se abre desde el final).
    @Published var hasOlderHistory = false
    @Published var isLoadingOlder = false
    private var historyWindowStart: Int64 = 0
    /// Resultado del último indexado. La UI todavía no lo muestra: es la costura para la búsqueda (3.3).
    /// Id del mensaje al que hay que volver después de anteponer historial: así el texto no salta.
    @Published var scrollAnchor: String?

    @Published var indexResult: SessionIndexer.Result?

    // Spaces (4.1). La organización es de P4W; las conversaciones siguen siendo de Pi.
    @Published var spaces: [Space] = []
    @Published var spacesError: String?
    /// Conversaciones fijadas: el reciclador no las toca aunque no sean la visible.
    @Published var pinnedPaths: Set<String> = []
    /// Grupos de conversaciones que parecen un tema, propuestos como space. **Nada se mueve solo.**
    @Published var clusterSuggestions: [ClusterSuggestion] = []
    /// Nombres pedidos al modelo: cuántos se hicieron en esta corrida. Se muestra a propósito, para que
    /// el costo no sea invisible.
    @Published var namingRequests = 0
    @Published var isNamingClusters = false
    /// Cuánto tienen que parecerse dos conversaciones para caer en el mismo grupo. Elegido midiendo el
    /// historial real (0,15 → 166 grupos · 0,20 → 215 · 0,25 → 272).
    static let clusterThreshold: Double = 0.2
    /// Space activo: es donde cae una conversación nueva. `nil` = ninguna, va al historial.
    @Published var activeSpaceID: String?
    /// Space elegido para una conversación que todavía no tiene archivo. No se puede anotar una ruta
    /// que no existe, así que se anota la intención y se cumple cuando el archivo aparece.
    private var pendingSpaceID: String?
    private var spacesStore: SpacesStore?
    private var preferences: PreferencesStore?
    /// Lo que las extensiones están reportando: la clave y su texto, en orden de llegada.
    @Published var extensionStatuses: [(key: String, text: String)] = []

    // Configuración de Pi (3.6). P4W no tiene configuración propia: esto es la de Pi.
    @Published var settingsSchema: [PiSettingsSchema.Setting] = []
    @Published var settingsValues: [String: String] = [:]
    @Published var settingsDocPath: String?
    @Published var settingsExternalChange = false
    @Published var settingsMessage: String?
    @Published var settingsError: String?
    private var settingsStore: PiSettingsStore?
    @Published var indexError: String?
    @Published var historyTruncated = false
    /// Conversación recién creada, todavía sin archivo propio en disco.
    @Published var isNewConversation = false

    // Conversación
    @Published var items: [ChatItem] = []
    @Published var statusNote: String?
    @Published var dialogs: [DialogRequest] = []
    @Published var draft = ""
    @Published var attachments: [AttachmentRef] = []
    @Published var isSending = false

    // Agentes
    @Published var agents: [InstanceSummary] = []
    @Published var showAgentPanel = false
    /// Filtro del panel, con la forma de `pi-agent-board`: `s:blocked` o texto libre.
    @Published var agentFilter = ""

    // Entorno
    @Published var environmentNote = ""
    @Published var supervisorError: String?
    @Published var profiles: [ProfileSpec] = ProfileSpec.builtIn
    @Published var selectedProfileName = "lean"
    @Published var lastError: String?

    // Modelo y thinking: se leen y se cambian por RPC, como lo hace Pi en su propia TUI.
    @Published var models: [ModelOption] = []
    @Published var currentModel: ModelOption?
    @Published var thinkingLevels: [String] = []
    @Published var currentThinkingLevel: String?

    private(set) var piPath: String?
    private var supervisor: InstanceSupervisor?
    /// Los borradores, uno por conversación.
    private var draftStore: DraftStore?
    /// De qué conversación es el transcript que está en memoria.
    ///
    /// Hay **un solo** transcript para la app —no tiene sentido tener 470 en memoria—, pero tiene dueño: solo
    /// los eventos de la conversación que está en pantalla se dibujan. Lo demás vive en el nivel 1, que es el
    /// estado del supervisor, y por eso no cuesta memoria dibujarlo.
    private var transcriptOwner: String?

    /// De qué conversación es el texto que hoy está en el campo. `nil` = conversación nueva, sin archivo
    /// todavía (se guarda bajo una clave fija, así igual sobrevive).
    private var draftKey: String?
    /// Clave de la conversación nueva, que todavía no tiene archivo en disco.
    private static let newConversationDraftKey = "nueva"
    /// Lo último que se envió, esperando la confirmación para olvidar su borrador.
    private var pendingSentDraft: (key: String, text: String)?
    private var draftSaveTask: Task<Void, Never>?
    /// El observador del cierre de la app, para poder quitarlo.
    private var terminationObserver: NSObjectProtocol?

    /// Último estado dibujado en el Dock, para no redibujar el ícono al pedo.
    private var lastDockState: CatState?

    private var instance: ManagedInstance?
    /// Cómo volver a abrir la conversación si el reaper la apagó.
    private var currentRef: SessionRef?
    /// Evita que el reaper toque lo que se está viendo (y lo que se está enviando).
    private var pinnedKey: String?
    private let transcript = LiveTranscript()
    /// Índice local. Si no se puede abrir, P4W funciona igual: se degrada sin romperse.
    private var index: SessionIndex?
    /// Progreso del revelado del mensaje en curso. Vive acá y no en la vista: un LazyVStack
    /// descarta sus views y con ellos su @State.
    let reveal = RevealAnimator()
    private var refreshTimer: Timer?

    var selectedProfile: ProfileSpec {
        profiles.first { $0.name == selectedProfileName } ?? profiles.first ?? .lean
    }

    /// Los perfiles se arman con **lo que hay instalado**: no hay una lista escrita a mano.
    ///
    /// El default es el liviano **con caché**, no el liviano a secas. Apagar extensiones ahorra memoria
    /// pero gasta tokens: sin el caché de prefijo, la entrada de DeepSeek se paga completa (hasta 98 %
    /// más caro). La extensión es un archivo, así que la memoria y el arranque casi no cambian.
    private func buildProfiles() -> [ProfileSpec] {
        let catalog = PiExtensionCatalog.discover()
        var built: [ProfileSpec] = [.lean]

        let cache = catalog.first { $0.name.contains("deepseek-cache") }
        let web = catalog.first { $0.name.contains("web-access") }

        if let cache {
            built.append(.lean(with: [cache], name: "lean-cache", label: "lean + caché"))
        }
        if let cache, let web {
            built.append(.lean(with: [cache, web],
                               name: "lean-cache-web", label: "lean + caché + web"))
        } else if let web {
            built.append(.lean(with: [web], name: "lean-web", label: "lean + web"))
        }
        built.append(.capabilities)
        built.append(.full)
        return built
    }

    /// Título de la barra. Una conversación nueva todavía no tiene archivo, así que no tiene nombre.
    var windowTitle: String {
        if let current { return current.displayTitle }
        return isNewConversation ? "Conversación nueva" : "P4W"
    }

    /// El chat muestra su propio estado vacío, no un historial que no existe.
    var showsEmptyConversationPlaceholder: Bool {
        isNewConversation && items.isEmpty
    }

    /// Busca con un retardo corto: consultar en cada tecla castiga sin necesidad, y el FTS es
    /// rápido pero no gratis.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let index else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let hits = (try? index.searchHits(query)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchHits = hits
                self.isSearching = false
            }
        }
    }

    /// La conversación detrás de un resultado de búsqueda.
    func session(forPath path: String) -> SessionSummary? {
        sessions.first { $0.path == path }
    }

    var filteredSessions: [SessionSummary] {
        guard !searchText.isEmpty else { return sessions }
        let needle = searchText.lowercased()
        return sessions.filter {
            $0.displayTitle.lowercased().contains(needle)
                || $0.preview.lowercased().contains(needle)
                || ($0.cwd ?? "").lowercased().contains(needle)
        }
    }

    // MARK: Arranque

    init() {
        let environment = ShellEnvironment.resolve()
        environmentNote = environment.diagnostic

        if let pi = environment.piExecutable {
            piPath = pi.path
            let config = SupervisorConfig(
                piExecutable: pi,
                defaultProfile: .lean,
                reapAfterSeconds: 30,
                maxLiveInstances: 2,
                reapOnMemoryPressure: true
            )
            let supervisor = InstanceSupervisor(config: config, environment: environment)
            supervisor.onSnapshot = { [weak self] snapshot in
                Task { @MainActor in
                    // Ordenado por atención en el origen: la vista no reordena nada.
                    let ordered = AgentAttention.sorted(snapshot)
                    self?.agents = ordered
                    // El panel se muestra solo cuando aporta: más de una conversación, o alguna que
                    // te necesita (que es justamente cuando hay que verlo).
                    self?.showAgentPanel = ordered.count > 1 || AgentAttention.attentionCount(ordered) > 0
                }
            }
            supervisor.onReap = { [weak self] _, outcome in
                Task { @MainActor in
                    self?.statusNote = "Liberé memoria — \(outcome.summary)"
                }
            }
            supervisor.start()
            self.supervisor = supervisor
        } else {
            supervisorError = """
            No encontré `pi`. P4W no puede conversar sin él.
            Buscado en: \(environment.path.split(separator: ":").prefix(4).joined(separator: ":"))…
            Instalalo con:  curl -fsSL https://pi.dev/install.sh | sh
            """
        }

        transcript.onChange = { [weak self] in
            Task { @MainActor in self?.syncFromTranscript() }
        }

        // Los perfiles dependen de lo instalado, así que se arman acá y no en una constante.
        profiles = buildProfiles()
        preferences = try? PreferencesStore()
        // El orden es: lo que la persona eligió antes → el liviano con caché si está disponible → lean.
        // Se respeta la elección guardada por encima del default recomendado: si alguien eligió `full`,
        // no corresponde cambiárselo en cada arranque.
        if let saved = preferences?.string(.defaultProfile),
           profiles.contains(where: { $0.name == saved }) {
            selectedProfileName = saved
        } else if let preferred = profiles.first(where: { $0.name == "lean-cache" }) {
            selectedProfileName = preferred.name
        }

        do {
            spacesStore = try SpacesStore()
            draftStore = try DraftStore()
            // Cerrar la app es uno de los cuatro momentos de volcado: el texto no puede depender del
            // guardado con retraso, que puede no haber llegado a correr.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveDraft() }
            }
            spaces = spacesStore?.all() ?? []
            pinnedPaths = spacesStore?.pinnedPaths() ?? []
            applyPinning()
        } catch {
            // Si los espacios fallan, las conversaciones siguen estando: se pierde la organización,
            // no el trabajo. Se avisa y se sigue.
            spacesError = "\(error)"
        }

        do {
            index = try SessionIndex()
        } catch {
            indexError = "No pude abrir el índice: \(error). La búsqueda no va a estar disponible."
        }

        Notifier.requestPermissionIfPossible()
        loadSessions()

        // Latido lento **de respaldo**: el supervisor ya avisa cuando algo cambia de verdad, así que
        // este timer solo existe para refrescar lo que cambia solo (tiempo ocioso, memoria) y para
        // destrabar la interfaz si un run muere sin avisar. Cada 5 s alcanza y sobra; cada 1,5 s
        // obligaba a redibujar todo el panel todo el tiempo.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAgents() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: Sesiones

    /// Arranque en dos tiempos: **primero lo que ya está indexado** (instantáneo), después el
    /// refresco incremental en segundo plano. Con 271 conversaciones el aporte del refresco es de
    /// milisegundos porque no abre ningún archivo que no haya cambiado.
    /// Modo de diagnóstico: abre la conversación más grande apenas está la lista. Existe para poder
    /// reproducir un cuelgue sin depender de un clic, y así poder muestrear el proceso para ver dónde
    /// se traba en vez de adivinarlo.
    func openBiggestForDiagnosis() {
        let openable = sessions.filter { $0.cwdIsAvailable }
        guard let biggest = openable.max(by: { $0.sizeBytes < $1.sizeBytes }) else { return }
        statusNote = "Diagnóstico: abriendo la más grande (\(biggest.sizeLabel))"
        open(biggest)
    }

    func loadSessions() {
        checkDependencies()
        // Una consulta por arranque como máximo, y solo si pasó un día desde la última: la regla vive en el
        // núcleo y se verifica ahí.
        checkForUpdates()
        let root = SessionCatalog.defaultRoot
        let index = self.index

        guard let index else {
            // Sin índice se cae al camino viejo: leer el catálogo completo. Más lento, pero anda.
            Task.detached(priority: .userInitiated) {
                let loaded = SessionCatalog.load(root: root)
                await MainActor.run { self.sessions = loaded }
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            // 1. Lo cacheado, ya.
            if let cached = try? index.allSessions(), !cached.isEmpty {
                await MainActor.run { self.sessions = cached }
            }
            // 2. Poner al día con el disco.
            do {
                let result = try SessionIndexer.refresh(index: index, root: root)
                let fresh = (try? index.allSessions()) ?? []
                await MainActor.run {
                    self.indexResult = result
                    if !fresh.isEmpty { self.sessions = fresh }
                    if CommandLine.arguments.contains("--open-biggest") {
                        self.openBiggestForDiagnosis()
                    }
                    // Con el índice al día se sabe qué conversaciones existen: los tabs que apuntan a
                    // otras se sacan solos, sin que quede nada colgando.
                    self.pruneSpaces(against: Set(fresh.map(\.path)))
                    self.refreshClusterSuggestions()
                }
            } catch {
                // Nunca se traga un error: si el índice falla, la app sigue andando sin él.
                await MainActor.run { self.indexError = "\(error)" }
                let loaded = SessionCatalog.load(root: root)
                await MainActor.run { self.sessions = loaded }
            }
        }
    }

    /// Abre una conversación: carga la rama activa del archivo y despierta (o lanza) su instancia.
    ///
    /// El historial se carga **dentro del transcript**, que es la única fuente de la lista que se
    /// muestra. Antes se asignaba a `items` y el primer evento en vivo lo pisaba: la conversación
    /// "abría" y quedaba vacía.
    func open(_ summary: SessionSummary) {
        // Un solo punto de guardado: cambiar de conversación guarda lo que había y trae lo de la nueva.
        // Antes esto no existía, y como el borrador era **uno solo para toda la app**, el texto se iba con
        // la conversación equivocada, listo para mandarse al lugar incorrecto.
        switchDraft(to: summary.path)
        current = summary
        // Sin esto, después de crear una conversación nueva el placeholder seguía tapando todo:
        // abrir cualquier conversación parecía no cargar nada.
        isNewConversation = false
        isLoadingHistory = true
        lastError = nil
        historyTruncated = false
        transcript.replaceItems([])

        // Se lee **el final** del archivo y se muestra ya. Y no se arranca ningún proceso: abrir una
        // conversación es leer un archivo. El proceso se despierta recién cuando hace falta enviar
        // algo (o una acción como renombrar), que es cuando Pi aporta algo.
        //
        // Antes, abrir lanzaba el proceso en el **hilo principal** y la ventana se congelaba: el
        // spawn, el handshake y hasta el reciclado de otra conversación bloqueaban la interfaz.
        Task.detached(priority: .userInitiated) {
            let window = SessionReader.loadTail(path: summary.path)
            let model = SessionReader.lastModelInfo(path: summary.path)
            await MainActor.run {
                self.transcript.replaceItems(window.items)
                self.historyWindowStart = window.startOffset
                self.hasOlderHistory = window.hasMore
                self.historyTruncated = window.hasMore
                self.isLoadingHistory = false
                self.applyModelFromFile(model)
            }
        }
    }

    /// Muestra el modelo que dice el archivo, sin despertar el proceso.
    private func applyModelFromFile(_ info: (provider: String, modelId: String)?) {
        guard let info else { return }
        currentModel = ModelOption(id: info.modelId, provider: info.provider,
                                   name: info.modelId, reasoning: false, contextWindow: nil)
    }

    /// Carga el tramo anterior del historial. La interfaz conserva la posición usando el id del
    /// primer mensaje visible.
    func loadOlder() {
        guard let current, !isLoadingOlder, hasOlderHistory else { return }
        let before = historyWindowStart
        let anchor = items.first?.id
        isLoadingOlder = true
        Task.detached(priority: .userInitiated) {
            let window = SessionReader.loadBefore(path: current.path, before: before)
            await MainActor.run {
                self.transcript.prependItems(window.items)
                self.historyWindowStart = window.startOffset
                self.hasOlderHistory = window.hasMore
                self.isLoadingOlder = false
                self.scrollAnchor = anchor
            }
        }
    }

    /// Arranca una conversación nueva. Pi la crea con `--session-id`; el archivo aparece en disco
    /// recién cuando se escribe el primer mensaje, así que la ubicamos en el catálogo al terminar.
    func newConversation() {
        // Solo se comprueba que haya supervisor: acá no se usa su valor.
        guard supervisor != nil else { return }
        switchDraft(to: nil)
        current = nil
        isNewConversation = true
        isLoadingHistory = false
        historyTruncated = false
        lastError = nil
        transcript.replaceItems([])
        // No se arranca ningún proceso acá: crear una conversación es preparar el estado. El proceso
        // nace cuando se envía el primer mensaje (`ensureInstance`), fuera del hilo principal. Antes
        // esto adquiría en el hilo principal y la ventana se congelaba al crear una conversación.
        let newKey = UUID().uuidString
        currentRef = .new(id: newKey, directory: nil)
        pinnedKey = newKey
        applyPinning()
        currentModel = nil
        transcript.replaceItems([])
    }

    /// Busca en el catálogo la conversación recién creada y la selecciona, para que el sidebar
    /// quede consistente con lo que se está viendo.
    /// Busca en el catálogo la conversación nueva para dejarla seleccionada en el sidebar.
    /// **No controla lo que se muestra**: eso ya no depende de esto, así que si el archivo todavía
    /// no está escrito solo se reintenta, sin dejar la ventana en un estado raro.
    private func locateNewConversation(attempt: Int = 0) {
        guard let instance, current == nil else { return }
        let wanted = instance.sessionID
        let root = SessionCatalog.defaultRoot
        Task.detached(priority: .utility) {
            let loaded = SessionCatalog.load(root: root)
            await MainActor.run {
                self.sessions = loaded
                if let match = loaded.first(where: { $0.id == wanted }) {
                    self.current = match
                    // La conversación nueva ya tiene archivo, así que cambia su clave: el dueño del
                    // transcript y el enganche de la instancia pasan a la ruta nueva. Sin esto, la respuesta
                    // dejaría de dibujarse en cuanto Pi creara el archivo.
                    self.transcriptOwner = match.path
                    self.draftKey = match.path
                    if let instance = self.instance {
                        let ref = self.currentRef
                        self.bind(instance, ref: ref, key: match.path)
                    }
                    // Y ahora que el archivo existe, se cumple la intención del space activo.
                    if let spaceID = self.pendingSpaceID {
                        self.pendingSpaceID = nil
                        self.move(match, toSpaceID: spaceID)
                    }
                } else if attempt < 3 {
                    // El archivo puede tardar en aparecer; se reintenta sin bloquear nada.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self.locateNewConversation(attempt: attempt + 1)
                    }
                }
            }
        }
    }

    private func bind(_ instance: ManagedInstance, ref: SessionRef?, key: String?) {
        self.instance = instance
        if let ref { self.currentRef = ref }
        if let key {
            pinnedKey = key
            applyPinning()
        }
        instance.onEvent = { [weak self] event in
            guard let self else { return }
            // **Acá estaba el bug del multitasking.** El transcript es uno solo, así que si una conversación
            // que seguía trabajando en segundo plano aplicaba sus eventos, su razonamiento y sus herramientas
            // se dibujaban **en la conversación que se acababa de abrir**. Ahora cada enganche sabe de qué
            // conversación es y solo dibuja si es la que está en pantalla.
            //
            // Nada se pierde por no dibujarlo: el estado y los contadores de **todas** las instancias los
            // lleva el supervisor por su cuenta, así que el panel y el indicador no dependen de tener la
            // conversación abierta. Ese es el nivel 1.
            if key == nil || key == self.transcriptOwner {
                self.transcript.apply(event)
            }
            if case .agentSettled = event {
                // El cierre de la conversación que terminó: si es la que está en pantalla, se apaga el
                // "enviando". Si no, la que mira sigue esperando lo suyo y no se le toca nada.
                let esLaVisible = (key == nil || key == self.transcriptOwner)
                Task { @MainActor in
                    if esLaVisible {
                        self.isSending = false
                        self.locateNewConversation()
                    }
                    self.notifyIfNeeded()
                }
            }
        }
        refreshAgents()
        syncFromTranscript()
        refreshCapabilities()
    }

    /// Pide a Pi los modelos disponibles y los niveles de thinking del modelo activo.
    /// Se hace en segundo plano porque son dos llamadas RPC y la ventana no debe esperarlas.
    func refreshCapabilities() {
        guard let instance else { return }
        Task.detached(priority: .userInitiated) {
            let models = instance.availableModels()
            let levels = instance.availableThinkingLevels()
            let current = instance.currentModel
            let level = instance.thinkingLevel
            await MainActor.run {
                self.models = models
                self.thinkingLevels = levels
                self.currentModel = current
                self.currentThinkingLevel = level
            }
        }
    }

    /// Cambia el modelo de esta conversación. Pi lo registra en la sesión, así que reabrirla lo
    /// restaura sin tocar el predeterminado.
    func select(model: ModelOption) {
        guard let instance else { return }
        statusNote = "Cambiando a \(model.shortLabel)…"
        Task.detached(priority: .userInitiated) {
            let applied = instance.setModel(model)
            // Los niveles de thinking dependen del modelo: hay que releerlos.
            let levels = instance.availableThinkingLevels()
            let level = instance.thinkingLevel
            let error = instance.lastError
            await MainActor.run {
                if let applied {
                    self.currentModel = applied
                    self.statusNote = "Modelo: \(applied.shortLabel)"
                } else {
                    self.lastError = error ?? "No se pudo cambiar el modelo."
                    self.statusNote = nil
                }
                self.thinkingLevels = levels
                self.currentThinkingLevel = level
                if self.lastError == nil { self.lastError = nil }
            }
        }
    }

    func select(thinkingLevel: String) {
        guard let instance else { return }
        Task.detached(priority: .userInitiated) {
            let ok = instance.setThinkingLevel(thinkingLevel)
            let error = instance.lastError
            await MainActor.run {
                if ok {
                    self.currentThinkingLevel = thinkingLevel
                    self.statusNote = "Nivel de thinking: \(thinkingLevel)"
                } else {
                    self.lastError = error ?? "No se pudo cambiar el nivel de thinking."
                }
            }
        }
    }

    /// Envoltorio con la misma garantía: nunca adquiere en el hilo que llama.
    private func attachInstance(for summary: SessionSummary) {
        let profile = selectedProfile
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.rebindInstance(for: summary, profile: profile)
        }
    }

    // MARK: Conversación

    /// `Enter` envía. Si Pi está trabajando, encola una **guía** (como en Pi).
    func send() { send(requested: .now) }

    /// `Alt+Enter`. Si Pi está trabajando, encola un **seguimiento** (como en Pi).
    func sendFollowUp() { send(requested: .followUp) }

    private func send(requested: ManagedInstance.SendMode) {
        let files = attachments.filter { !$0.isImage }.compactMap(\.path)
        var text = draft
        if !files.isEmpty {
            // El idioma nativo de Pi: se referencia la ruta, no se copia el contenido (§7.1).
            let references = files.map { "@\($0)" }.joined(separator: "\n")
            text = text.isEmpty ? references : text + "\n\n" + references
        }
        let images = attachments.filter(\.isImage).map { attachment in
            ["type": "image", "data": attachment.imageBase64 ?? "",
             "mimeType": attachment.mimeType ?? "image/png"]
        }
        guard !text.isEmpty || !images.isEmpty else { return }

        // Si hay un space activo, la conversación nueva va a caer ahí cuando su archivo exista.
        pendingSpaceID = activeSpaceID

        // La conversación ya arrancó: dejar de mostrar el estado "nueva" es lo que hacía que el
        // mensaje recién enviado no apareciera.
        // Si ya hay un turno en curso, el mensaje se encola y hay que decirlo en la burbuja.
        let busy = instance?.isWorking ?? false
        let queued: ChatItem.Queued? = !busy ? nil
            : (requested == .followUp ? .followUp : .steering)

        isNewConversation = false
        transcript.appendUser(text: text, attachments: attachments, queued: queued)
        // El borrador **no se borra acá**: se olvida cuando el texto ya está en la conversación. Si el envío
        // falla, tiene que poder volver; y si la app se cierra en el medio, tampoco puede perderse.
        pendingSentDraft = (key: draftKey ?? Self.newConversationDraftKey, text: text)
        draft = ""
        attachments = []
        isSending = true
        lastError = nil

        // En segundo plano por dos razones: si el reaper apagó la conversación hay que despertarla
        // (puede tardar segundos) y la ventana no puede quedarse congelada esperando.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let ready = await self.ensureInstance() else { return }
            do {
                try ready.send(text, images: images, requested: requested)
            } catch {
                await MainActor.run {
                    self.isSending = false
                    self.lastError = "No pude enviar: \(error)"
                }
            }
        }
    }

    /// Devuelve una instancia usable, despertándola si el reaper la apagó. Que se apague para
    /// liberar memoria **no** debe romperle la conversación al usuario.
    private func ensureInstance() async -> ManagedInstance? {
        if let instance, instance.isReusable { return instance }
        guard let supervisor, let ref = currentRef else {
            await MainActor.run {
                self.isSending = false
                self.lastError = "No hay conversación abierta."
            }
            return nil
        }
        await MainActor.run { self.statusNote = "Despertando la conversación…" }
        let key = ref.key
        let profile = await MainActor.run { self.selectedProfile }
        let revived = try? await Task.detached(priority: .userInitiated) {
            try supervisor.acquire(ref, profile: profile)
        }.value
        guard let revived else {
            await MainActor.run {
                self.isSending = false
                self.statusNote = nil
                self.lastError = "No pude despertar la conversación."
            }
            return nil
        }
        await MainActor.run {
            self.statusNote = nil
            // La clave del enganche es la de la conversación que se está mirando: para una que ya existe es
            // su ruta, y para una nueva es la clave de "nueva" (la misma que usan los borradores).
            self.bind(revived, ref: ref, key: self.draftKey)
        }
        return revived
    }

    /// Detiene. **Primero saca la cola y la devuelve al editor**, como Pi: si no, los mensajes
    /// encolados se iban con el abort y se perdía lo que la persona había escrito.
    func stop() {
        let running = instance
        Task.detached(priority: .userInitiated) {
            let pending = running?.clearQueue() ?? (steering: [], followUp: [])
            await MainActor.run {
                let restored = (pending.steering + pending.followUp).joined(separator: "\n\n")
                if !restored.isEmpty {
                    self.draft = self.draft.isEmpty ? restored : restored + "\n\n" + self.draft
                    self.statusNote = "Devolví \(pending.steering.count + pending.followUp.count) mensaje(s) encolado(s) al editor."
                } else {
                    self.statusNote = "Detenido."
                }
                self.transcript.clearQueued()
            }
            running?.abort()
        }
        isSending = false
    }

    /// Qué conversaciones son intocables para el reciclador: la visible, siempre, más las fijadas.
    private func applyPinning() {
        var keys = pinnedPaths
        if let pinnedKey { keys.insert(pinnedKey) }
        supervisor?.setPinned(keys)
    }

    func togglePin(_ session: SessionSummary) {
        if pinnedPaths.contains(session.path) {
            pinnedPaths.remove(session.path)
            statusNote = "Ya no está fijada."
        } else {
            pinnedPaths.insert(session.path)
            statusNote = "Fijada: no se va a liberar de memoria."
        }
        try? spacesStore?.setPinned(pinnedPaths)
        applyPinning()
    }

    // MARK: Secciones del sidebar

    /// Qué secciones están plegadas. Vive en `spaces.json`, junto a los tabs fijados: es lo mismo, el orden
    /// propio de la columna. Antes vivía en un `@State` de la vista y **se perdía en cada arranque**.
    var collapsedSections: Set<String> { spacesStore?.collapsedKeys() ?? [] }

    func isCollapsed(_ sectionKey: String) -> Bool {
        collapsedSections.contains(sectionKey)
    }

    func toggleSection(_ sectionKey: String) {
        let nowCollapsed = !isCollapsed(sectionKey)
        try? spacesStore?.setCollapsed(nowCollapsed, section: sectionKey)
        objectWillChange.send()
    }

    // MARK: Borradores y deshacer

    /// Cambia el borrador activo: guarda el que había y trae el de la conversación nueva.
    private func switchDraft(to path: String?) {
        saveDraft()
        draftKey = path ?? Self.newConversationDraftKey
        // La misma clave identifica a la conversación que se está mirando: es la dueña del transcript.
        transcriptOwner = draftKey
        draft = draftStore?.text(for: draftKey ?? "") ?? ""
    }

    /// Un cambio de lo que escribió la persona. Lo llama el campo en cada tecla.
    func draftChanged(_ text: String) {
        guard text != draft else { return }
        draft = text
        scheduleDraftSave()
    }

    /// Guarda el texto que está en el campo, si cambió.
    func saveDraft() {
        guard let draftStore, let key = draftKey else { return }
        try? draftStore.set(draft, for: key)
    }

    /// Guarda con retraso: escribir no puede castigar el disco en cada tecla, pero tampoco puede perderse.
    /// El retraso es corto, y hay volcado inmediato en los momentos que importan: cambiar de conversación,
    /// cerrar una pestaña, enviar y cerrar la app.
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.saveDraft() }
        }
    }

    /// Olvida el borrador cuando su texto **ya está en la conversación**: eso es la confirmación.
    func forgetConfirmedDraft() {
        guard let pending = pendingSentDraft, let draftStore else { return }
        let inConversation = transcript.items.contains { item in
            item.author == .user && !pending.text.isEmpty
                && item.text.hasPrefix(pending.text.prefix(40))
        }
        guard inConversation else { return }
        try? draftStore.remove(for: pending.key)
        pendingSentDraft = nil
    }

    // MARK: Actualizaciones

    /// El último resultado de la consulta. `nil` = todavía no se consultó.
    @Published var updateOutcome: UpdateCheck.Outcome?
    @Published var isCheckingUpdates = false

    var currentVersion: ReleaseVersion? { P4WVersion.release }

    private var lastUpdateCheck: Date? {
        get {
            guard let raw = preferences?.string(.lastUpdateCheck), let seconds = Double(raw) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
        set {
            try? preferences?.set(newValue.map { String($0.timeIntervalSince1970) },
                                 for: .lastUpdateCheck)
        }
    }

    private var dismissedUpdateVersion: String? { preferences?.string(.dismissedUpdateVersion) }

    var availableUpdate: UpdateInfo? { updateOutcome?.update }

    /// Si corresponde mostrar el aviso. Las reglas están en el núcleo, no acá: son una decisión, y así se
    /// verifican sin abrir la app.
    var showsUpdateNotice: Bool {
        UpdateNotice.shouldShow(outcome: updateOutcome,
                                dismissedVersion: dismissedUpdateVersion,
                                piIsWorking: instance?.isRunActive ?? false)
    }

    func dismissUpdate() {
        guard let version = availableUpdate?.version else { return }
        try? preferences?.set(version.description, for: .dismissedUpdateVersion)
        objectWillChange.send()
    }

    /// Consulta si hay una versión nueva.
    ///
    /// - Parameter force: la consulta a mano (desde el menú). Ignora la regla de una por día y **siempre
    ///   responde algo**: al día, hay una nueva, o no se pudo consultar. Una búsqueda manual que no dice
    ///   nada deja la duda.
    func checkForUpdates(force: Bool = false) {
        guard let current = currentVersion else { return }
        if !force, !UpdateCheck.shouldCheck(lastCheck: lastUpdateCheck) { return }
        if isCheckingUpdates { return }
        lastUpdateCheck = Date()
        isCheckingUpdates = true
        if force { statusNote = "Buscando actualizaciones…" }

        Task.detached(priority: .utility) {
            let outcome = await UpdateCheck.latest(current: current)
            await MainActor.run {
                self.isCheckingUpdates = false
                self.updateOutcome = outcome
                // Solo la consulta a mano escribe en la línea de estado: la automática no interrumpe.
                if force {
                    switch outcome {
                    case .upToDate(let version):
                        self.statusNote = "Ya estás en la última versión (\(version))."
                    case .available(let info):
                        self.statusNote = "Hay una versión nueva: \(info.version)."
                    case .unknown(let reason):
                        self.statusNote = "No se pudo consultar: \(reason)"
                    }
                }
            }
        }
    }

    // MARK: Dependencias

    /// Qué hay y qué falta. Se llena al arrancar, en segundo plano.
    @Published var dependencies: DependencyReport?

    /// Los avisos que la persona ya descartó. **Los obligatorios no se pueden descartar**: si falta `pi`,
    /// no hay app que usar, y dejar silenciar eso sería esconder el problema en vez de resolverlo.
    var dismissedDependencyIDs: Set<String> {
        Set((preferences?.string(.dismissedDependencies) ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    func dismissDependency(id: String) {
        guard let item = dependencies?.items.first(where: { $0.id == id }), item.level != .obligatorio else {
            return
        }
        var ids = dismissedDependencyIDs
        ids.insert(id)
        try? preferences?.set(ids.sorted().joined(separator: ","), for: .dismissedDependencies)
        objectWillChange.send()
    }

    /// Corre el chequeo fuera del hilo principal: lee archivos, y la ventana no tiene por qué esperar.
    func checkDependencies() {
        Task.detached(priority: .utility) {
            let report = DependencyCheck.run()
            await MainActor.run { self.dependencies = report }
        }
    }

    /// Lo que la UI tiene que mostrar: lo obligatorio que falta **siempre**, y lo demás si no se descartó.
    var visibleDependencyIssues: [DependencyItem] {
        guard let report = dependencies else { return [] }
        let dismissed = dismissedDependencyIDs
        return report.items.filter { item in
            guard !item.present else { return false }
            if item.level == .obligatorio { return true }
            return !dismissed.contains(item.id)
        }
    }

    // MARK: El avatar

    /// Cuánto mide el gato. Se cambia desde el mismo menú que la ubicación.
    var avatarSize: CatSize {
        get { CatSize.from(preferences?.string(.avatarSize)) }
        set {
            try? preferences?.set(newValue.rawValue, for: .avatarSize)
            objectWillChange.send()
        }
    }

    /// Si el ícono del Dock sigue el estado de Pi. Encendido salvo que se apague.
    var dockIconLive: Bool {
        get { preferences?.string(.dockIconLive) != "false" }
        set {
            try? preferences?.set(newValue ? "true" : "false", for: .dockIconLive)
            objectWillChange.send()
            syncDockIcon(force: true)
        }
    }

    /// Pone en el Dock el gato en la pose del estado actual.
    ///
    /// Sirve para lo que el gato de la ventana no puede: **cuando la ventana está tapada por otra**. Ahí el
    /// Dock sigue visible, así que se ve si Pi terminó sin traer la ventana al frente.
    ///
    /// Se actualiza **solo cuando el estado cambia**, nunca por cuadro de animación: dibujar un PNG de 256
    /// por cuadro sería justo lo que este proyecto no hace. Y si el estado no cambió, acá no pasa nada.
    func syncDockIcon(force: Bool = false) {
        guard dockIconLive else {
            if lastDockState != nil || force {
                lastDockState = nil
                NSApp.applicationIconImage = IconRenderer.dockImage(for: .enReposo)
            }
            return
        }
        let state = catState
        guard force || state != lastDockState else { return }
        lastDockState = state
        if let image = IconRenderer.dockImage(for: state) {
            NSApp.applicationIconImage = image
        }
    }

    /// Si la persona ya eligió dónde va el gato.
    ///
    /// Se deduce de que la preferencia **exista**: si nunca la tocó, todavía no sabe que se puede mover, y
    /// conviene decírselo. Una vez que elige, la explicación se apaga sola.
    var hasChosenAvatarPosition: Bool { preferences?.string(.avatarPosition) != nil }

    /// Si ya se descartó la explicación a mano.
    var avatarHintDismissed: Bool { preferences?.string(.avatarHintDismissed) == "true" }

    /// Si conviene explicar que el gato se puede mover: nunca eligió, y no la descartó.
    var showsAvatarHint: Bool { !hasChosenAvatarPosition && !avatarHintDismissed }

    func dismissAvatarHint() {
        try? preferences?.set("true", for: .avatarHintDismissed)
        objectWillChange.send()
    }

    /// Dónde vive el gato. Se cambia desde el menú del propio gato, sin entrar a configuración: es una
    /// decisión de mirarlo, y se decide mirándolo.
    var avatarPosition: AvatarPosition {
        get { AvatarPosition.from(preferences?.string(.avatarPosition)) }
        set {
            try? preferences?.set(newValue.rawValue, for: .avatarPosition)
            objectWillChange.send()
        }
    }

    /// En qué anda Pi, para el gato. Sale de lo que ya existe: **no hay una segunda clasificación** de
    /// estados que pueda desincronizarse del stream.
    var catState: CatState {
        let last = items.last
        let runningTools = last?.tools.filter(\.isRunning).count ?? 0
        return CatStateMachine.derive(
            instanceState: instance?.state,
            isRunActive: instance?.isRunActive ?? false,
            pendingDialogs: instance?.pendingDialogCount ?? 0,
            runningTools: runningTools,
            liveThinking: instance?.liveThinking ?? "",
            liveText: last?.author == .assistant ? (last?.text ?? "") : "",
            lastRunFailed: instance?.lastRunErrored ?? false
        )
    }

    // MARK: Sugerencias de space (agrupación sin modelo)

    /// Agrupa si hace falta y arma las sugerencias.
    ///
    /// Corre en segundo plano: agrupar tarda ~315 ms sobre 470 conversaciones, y no hay motivo para que
    /// la ventana espere. Los conteos de términos ya están guardados por el indexado, así que acá **no se
    /// lee ningún archivo**.
    func refreshClusterSuggestions() {
        guard let index else { return }
        let assigned = Set(spaces.flatMap { $0.tabs.map(\.sessionPath) })
        let dismissed = spacesStore?.dismissedClusterKeys() ?? []
        let threshold = Self.clusterThreshold

        Task.detached(priority: .utility) {
            // Se agrupa si el resultado guardado quedó viejo (no solo si no hay ninguno): si aparecieron
            // conversaciones nuevas o cambió el umbral, hay que rehacerlo.
            if (try? ClusterIndexer.needsRebuild(index: index, threshold: threshold)) == true {
                _ = try? ClusterIndexer.rebuild(index: index, threshold: threshold)
            }
            let clusters = (try? index.loadClusters()) ?? []
            var members: [Int: [String]] = [:]
            for cluster in clusters {
                members[cluster.id] = (try? index.paths(inCluster: cluster.id)) ?? []
            }
            let names = (try? index.clusterNames()) ?? [:]
            let built = ClusterSuggestions.build(clusters: clusters, membersByCluster: members,
                                                 assignedPaths: assigned, dismissed: dismissed,
                                                 names: names)
            await MainActor.run {
                self.clusterSuggestions = built
                // Encendido, nombrar es automático — pero también al arrancar, no solo al tocar el
                // interruptor: si no, dejarlo encendido no serviría de nada hasta la próxima vez.
                if self.namesClustersWithModel,
                   built.contains(where: { $0.modelName == nil }) {
                    self.nameClustersWithModel()
                }
            }
        }
    }

    /// Nombrar con el modelo, apagable. Ausente en las preferencias = **apagado**.
    var namesClustersWithModel: Bool {
        get { preferences?.string(.nameClustersWithModel) == "true" }
        set {
            try? preferences?.set(newValue ? "true" : "false", for: .nameClustersWithModel)
            objectWillChange.send()
            if newValue { nameClustersWithModel() }
        }
    }

    /// Le pide al modelo un nombre por grupo: **un pedido por grupo**, no por conversación, y cacheado
    /// por clave, así que un grupo no se renombra dos veces.
    ///
    /// Si algo falla —el proceso, el modelo, la respuesta— queda la etiqueta heurística. Esa es la regla:
    /// el nombre del modelo **mejora** lo que ya hay, nunca lo reemplaza por nada.
    func nameClustersWithModel() {
        guard let index, let supervisor, !isNamingClusters else { return }
        // De a tandas de 12, **de a un proceso por vez**: no es un tope de gasto, es no encadenar
        // decenas de procesos seguidos. Con la preferencia encendida se terminan nombrando todos los
        // grupos que falten (28 en el historial real), y cuántos se pidieron queda a la vista.
        let pending = Array(clusterSuggestions.filter { $0.modelName == nil }.prefix(12))
        guard !pending.isEmpty else {
            statusNote = "Todos los grupos visibles ya tienen nombre."
            return
        }
        let titles = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.path, $0.name ?? String($0.preview.prefix(60)))
        })
        isNamingClusters = true
        statusNote = "Pidiendo nombres al modelo…"

        Task.detached(priority: .utility) {
            var made = 0
            var named = 0
            for suggestion in pending {
                let work = "\(NSTemporaryDirectory())p4w-naming-\(UUID().uuidString.prefix(8))"
                try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: work) }
                // Sesión propia y descartable: nombrar no puede ensuciar el historial de nadie.
                let ref = SessionRef.new(id: "p4w-naming-\(UUID().uuidString.prefix(8))",
                                         directory: work)
                guard let instance = try? supervisor.acquire(ref, profile: .lean) else { continue }
                defer { _ = supervisor.release(ref.key) }

                let prompt = ClusterNaming.prompt(
                    terms: suggestion.topTerms,
                    titles: suggestion.members.compactMap { titles[$0] }
                )
                // El cierre solo toca esta caja, que tiene candado: nada de capturar variables mutables
                // desde el hilo de eventos.
                let waiter = TextWaiter()
                instance.onEvent = { waiter.apply($0) }
                guard (try? instance.sendPrompt(prompt)) != nil else { continue }
                made += 1
                guard waiter.waitSettled(timeout: 60),
                      let name = ClusterNaming.clean(waiter.text) else { continue }
                if (try? index.saveClusterName(name, forKey: suggestion.key)) != nil { named += 1 }
            }
            // Se copian a constantes antes de cruzar al actor principal: un cierre que corre en otro
            // actor no puede leer variables mutables del task (carrera de datos, y error en Swift 6).
            let requestsMade = made
            let groupsNamed = named
            await MainActor.run {
                self.isNamingClusters = false
                self.namingRequests += requestsMade
                self.statusNote = groupsNamed > 0
                    ? "\(groupsNamed) grupos nombrados por el modelo (\(requestsMade) pedidos)."
                    : "El modelo no devolvió nombres usables: quedan las etiquetas del grupo."
                self.refreshClusterSuggestions()
            }
        }
    }

    /// Acepta una sugerencia: crea el space con esas conversaciones. La persona pone el nombre (viene
    /// propuesto desde los términos del grupo) y puede cancelar.
    func accept(_ suggestion: ClusterSuggestion) {
        guard let name = Prompts.ask(
            "Crear un space con estas conversaciones",
            message: "Se van a mover \(suggestion.size) conversaciones. Podés cambiar las que quieras después.",
            defaultValue: suggestion.suggestedName
        ) else { return }
        guard let space = createSpace(named: name) else { return }
        var moved = 0
        for path in suggestion.members {
            guard let session = sessions.first(where: { $0.path == path }) else { continue }
            move(session, toSpaceID: space.id)
            moved += 1
        }
        statusNote = "Space «\(name)» creado con \(moved) conversaciones."
        refreshClusterSuggestions()
    }

    /// Ignora una sugerencia. Se recuerda para no volver a proponerla: una sugerencia que reaparece
    /// siempre es peor que no tener sugerencias.
    func dismiss(_ suggestion: ClusterSuggestion) {
        try? spacesStore?.dismissCluster(key: suggestion.key)
        clusterSuggestions.removeAll { $0.key == suggestion.key }
        statusNote = "Sugerencia descartada. No vuelve a aparecer."
    }

    // MARK: Pestañas y atajos

    /// Las conversaciones entre las que se puede cambiar con el teclado: las del space activo, o las
    /// más recientes si no hay ninguno. No recorre las 467 del historial: ciclar por 467 no sirve.
    var switchableTabs: [SessionSummary] {
        if let activeSpaceID, let space = spaces.first(where: { $0.id == activeSpaceID }) {
            let tabs = sessions(inSpace: space)
            if !tabs.isEmpty { return tabs }
        }
        return Array(filteredSessions.prefix(9))
    }

    /// `⌘1…9`: va a la pestaña n.
    func selectTab(_ number: Int) {
        let tabs = switchableTabs
        guard number >= 1, number <= tabs.count else { return }
        open(tabs[number - 1])
    }

    /// `⌃Tab`: siguiente pestaña, dando la vuelta.
    func nextTab() {
        let tabs = switchableTabs
        guard tabs.count > 1 else { return }
        guard let current, let index = tabs.firstIndex(where: { $0.path == current.path }) else {
            open(tabs[0])
            return
        }
        open(tabs[(index + 1) % tabs.count])
    }

    /// `⌘W`: cierra la conversación. **No borra nada**: deja de mostrarla y suelta el proceso si no
    /// está fijada. Volver a abrirla desde el historial la trae de vuelta igual.
    func closeCurrentTab() {
        saveDraft()
        guard let current else { return }
        if pinnedKey == current.path {
            supervisor?.release(current.path)
            instance = nil
            pinnedKey = nil
        }
        self.current = nil
        transcript.replaceItems([])
        hasOlderHistory = false
        statusNote = "Cerrada. Sigue en el historial."
        applyPinning()
    }

    /// Estado de una conversación, para el punto de color en la lista.
    func state(for session: SessionSummary) -> InstanceState? {
        agents.first { $0.sessionKey == session.path }?.state
    }

    // MARK: Spaces

    func refreshSpaces() {
        spaces = spacesStore?.all() ?? []
    }

    @discardableResult
    func createSpace(named name: String, color: Space.SpaceColor = .blue) -> Space? {
        do {
            let space = try spacesStore?.createSpace(name: name, color: color)
            refreshSpaces()
            return space
        } catch {
            spacesError = "\(error)"
            return nil
        }
    }

    func removeFromSpaces(sessionPath: String) throws {
        try spacesStore?.removeFromSpaces(sessionPath: sessionPath)
        refreshSpaces()
    }

    func reorderSpaces(ids: [String]) {
        try? spacesStore?.reorderSpaces(ids: ids)
        refreshSpaces()
    }

    func reorderTabs(inSpaceID id: String, sessionPaths: [String]) {
        try? spacesStore?.reorderTabs(inSpaceID: id, sessionPaths: sessionPaths)
        refreshSpaces()
    }

    func renameSpace(id: String) {
        guard let space = spaces.first(where: { $0.id == id }),
              let name = Prompts.ask("Renombrar space",
                                     message: "Es solo una etiqueta de P4W: no cambia nada en Pi.",
                                     defaultValue: space.name) else { return }
        try? spacesStore?.renameSpace(id: id, to: name)
        refreshSpaces()
    }

    func setColor(_ color: Space.SpaceColor, forSpace id: String) {
        try? spacesStore?.setColor(color, forSpace: id)
        refreshSpaces()
    }

    func deleteSpace(id: String) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        let confirmed = Prompts.confirm(
            "Borrar el space «\(space.name)»",
            message: "Se borra la organización, NO las conversaciones: las \(space.tabs.count) quedan "
                + "en el historial de Pi.",
            confirmTitle: "Borrar el space"
        )
        guard confirmed else { return }
        try? spacesStore?.deleteSpace(id: id)
        if activeSpaceID == id { activeSpaceID = nil }
        refreshSpaces()
        statusNote = "Space borrado. Las conversaciones siguen en el historial."
    }

    /// Las conversaciones que **no** están en ningún space: eso es el historial.
    ///
    /// Se excluyen las que ya están en un space para que no aparezcan dos veces. Nada desaparece:
    /// cada conversación está o en un space o acá, y la búsqueda cubre todo igual.
    var sessionsOutsideSpaces: [SessionSummary] {
        let assigned = Set(spaces.flatMap { $0.tabs.map(\.sessionPath) })
        return filteredSessions.filter { !assigned.contains($0.path) }
    }

    /// Las conversaciones de un space, en su orden guardado.
    func sessions(inSpace space: Space) -> [SessionSummary] {
        let byPath = Dictionary(uniqueKeysWithValues: sessions.map { ($0.path, $0) })
        return space.tabs.compactMap { byPath[$0.sessionPath] }
    }

    func move(_ session: SessionSummary, toSpaceID id: String) {
        do {
            try spacesStore?.move(sessionPath: session.path,
                                  profileName: selectedProfileName,
                                  toSpaceID: id)
            refreshSpaces()
        } catch {
            spacesError = "\(error)"
        }
    }

    /// Saca del tablero los tabs cuyos archivos ya no están. Se llama después de indexar, cuando se
    /// sabe qué conversaciones existen de verdad.
    func pruneSpaces(against paths: Set<String>) {
        guard let store = spacesStore else { return }
        do {
            let removed = try store.pruneTabs(existingPaths: paths)
            if removed > 0 {
                refreshSpaces()
                statusNote = "Saqué \(removed) pestaña(s) de conversaciones que ya no están."
            }
        } catch {
            spacesError = "\(error)"
        }
    }

    // MARK: Acciones sobre una conversación

    /// Todas las acciones de esta sección van **por RPC sobre un proceso vivo**, nunca escribiendo el
    /// `.jsonl` (invariante 1). Si la conversación estaba fría, se despierta: cuesta menos de un
    /// segundo con el perfil lean y el reaper la vuelve a apagar si nadie la usa.
    private func instance(for session: SessionSummary) async -> ManagedInstance? {
        if let instance, current?.path == session.path, instance.isReusable { return instance }
        guard let supervisor else { return nil }
        let profile = selectedProfile
        let ref = SessionRef.existing(path: session.path)
        return try? await Task.detached(priority: .userInitiated) {
            try supervisor.acquire(ref, profile: profile)
        }.value
    }

    /// Renombra. Aparece en los listados de Pi, igual que su `/name`.
    func rename(_ session: SessionSummary) {
        guard let proposed = Prompts.ask("Renombrar conversación",
                                         message: "El nombre aparece en los listados de Pi.",
                                         defaultValue: session.name ?? "") else { return }
        Task {
            guard let instance = await instance(for: session) else {
                lastError = "No pude abrir la conversación para renombrarla."
                return
            }
            let ok = instance.rename(to: proposed)
            if ok {
                statusNote = proposed.isEmpty ? "Nombre quitado." : "Renombrada: \(proposed)"
                // El índice guarda metadatos: se actualiza sin releer el archivo.
                try? index?.setName(proposed.isEmpty ? nil : proposed, path: session.path)
                if current?.path == session.path { current?.name = proposed.isEmpty ? nil : proposed }
                Notifier.requestPermissionIfPossible()
        loadSessions()
            } else {
                lastError = instance.lastError ?? "No se pudo renombrar."
            }
        }
    }

    /// Bifurca desde un mensaje elegido. Pi cambia de sesión en el mismo proceso, así que después hay
    /// que seleccionar la conversación nueva.
    func fork(_ session: SessionSummary) {
        Task {
            guard let instance = await instance(for: session) else {
                lastError = "No pude abrir la conversación para bifurcarla."
                return
            }
            let candidates = instance.forkCandidates()
            guard !candidates.isEmpty else {
                statusNote = "Esta conversación no tiene mensajes desde dónde bifurcar."
                return
            }
            // Se elige; el último (el más reciente) viene preseleccionado.
            guard let choice = Prompts.choose("Bifurcar desde un mensaje",
                                              message: "Se crea una conversación nueva que arranca en ese punto. La original no se toca.",
                                              options: candidates.map(\.label) ) else { return }
            guard let path = instance.fork(from: candidates[choice].entryId) else {
                lastError = instance.lastError ?? "No se pudo bifurcar."
                return
            }
            statusNote = "Bifurcada: \((path as NSString).lastPathComponent)"
            Notifier.requestPermissionIfPossible()
        loadSessions()
            // Y queda seleccionada cuando el catálogo la vea.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let fresh = sessions.first(where: { $0.path == path }) { open(fresh) }
            }
        }
    }

    /// Exporta a HTML y lo abre. Se le pasa la ruta para que el resultado sea predecible.
    func exportHTML(_ session: SessionSummary) {
        Task {
            guard let instance = await instance(for: session) else {
                lastError = "No pude abrir la conversación para exportarla."
                return
            }
            let folder = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("P4W/exports")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = session.displayTitle
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let destination = folder.appendingPathComponent("\(safeName).html").path
            guard let url = instance.exportHTML(to: destination) else {
                lastError = instance.lastError ?? "No se pudo exportar."
                return
            }
            statusNote = "Exportada a \((url.path as NSString).abbreviatingWithTildeInPath)"
            NSWorkspace.shared.open(url)
        }
    }

    /// Manda a la papelera y lo saca del índice. Nunca borra de verdad.
    func delete(_ session: SessionSummary) {
        let confirmed = Prompts.confirm(
            "Mover a la papelera",
            message: "«\(session.displayTitle)» se mueve a la papelera: se puede recuperar desde el Finder.",
            confirmTitle: "Mover a la papelera"
        )
        guard confirmed else { return }
        do {
            _ = try SessionCatalog.moveToTrash(path: session.path)
            try? index?.remove(paths: [session.path])
            if current?.path == session.path {
                current = nil
                transcript.replaceItems([])
            }
            sessions.removeAll { $0.path == session.path }
            // Y no queda una pestaña colgando apuntando a un archivo que ya no está.
            try? spacesStore?.removeFromSpaces(sessionPath: session.path)
            refreshSpaces()
            statusNote = "Movida a la papelera."
        } catch {
            lastError = "No se pudo mover a la papelera: \(error)"
        }
    }

    /// `Alt+Up`: devuelve al editor lo que está en cola, sin abortar.
    func dequeue() {
        guard let instance else { return }
        Task.detached(priority: .userInitiated) {
            let pending = instance.clearQueue()
            await MainActor.run {
                let restored = (pending.steering + pending.followUp).joined(separator: "\n\n")
                if !restored.isEmpty {
                    self.draft = self.draft.isEmpty ? restored : restored + "\n\n" + self.draft
                }
                self.transcript.clearQueued()
                self.statusNote = restored.isEmpty ? nil : "Mensajes devueltos al editor."
            }
        }
    }

    /// ¿Hay algo esperando turno?
    var hasQueuedMessages: Bool { transcript.queuedItems.isEmpty == false }

    /// Texto de ayuda mientras Pi trabaja, con los mismos atajos que la terminal.
    var workingHint: String? {
        guard instance?.isWorking == true else { return nil }
        if hasQueuedMessages {
            let count = transcript.queuedItems.count
            return "Pi está trabajando · \(count) mensaje\(count == 1 ? "" : "s") en cola"
        }
        return "Pi está trabajando · Intro encola una guía · ⌥Intro como seguimiento"
    }

    func waitForSettled() {
        isSending = false
    }

    func respond(to dialog: DialogRequest, value: String? = nil,
                 confirmed: Bool? = nil, cancelled: Bool = false) {
        guard let instance else { return }
        try? instance.respond(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled)
        dialogs.removeAll { $0.id == dialog.id }
    }

    func changeProfile(to name: String) {
        selectedProfileName = name
        // Se recuerda para el próximo arranque.
        try? preferences?.set(name, for: .defaultProfile)
        guard let summary = current else { return }
        // Cambiar de perfil implica relanzar el proceso. Va **fuera del hilo principal**: el spawn, el
        // handshake y el reciclado de otras conversaciones pueden tardar segundos.
        statusNote = "Cambiando a perfil \(name)…"
        let profile = selectedProfile
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ok = await self.rebindInstance(for: summary, profile: profile)
            await MainActor.run { self.statusNote = ok ? "Perfil: \(name)" : nil }
        }
    }

    /// Abre (o reabre) el proceso de una conversación, siempre fuera del hilo principal.
    @discardableResult
    private func rebindInstance(for summary: SessionSummary, profile: ProfileSpec) async -> Bool {
        guard let supervisor else { return false }
        let ref = SessionRef.existing(path: summary.path)
        let acquired = try? await Task.detached(priority: .userInitiated) {
            try supervisor.acquire(ref, profile: profile)
        }.value
        guard let acquired else {
            await MainActor.run { self.lastError = "No pude abrir el proceso de esta conversación." }
            return false
        }
        await MainActor.run { self.bind(acquired, ref: ref, key: summary.path) }
        return true
    }

    func addAttachment(from url: URL) {
        guard let attachment = AttachmentLoader.load(url: url) else { return }
        attachments.append(attachment)
    }

    // MARK: Estado derivado

    /// El transcript es la fuente: la UI solo copia lo que él dice.
    private func syncFromTranscript() {
        // Si el texto enviado ya está en la conversación, se olvida su borrador: eso es la confirmación.
        forgetConfirmedDraft()
        let fresh = transcript.items
        // Solo el último mensaje se anima, y solo mientras llega.
        let last = fresh.last
        reveal.update(itemID: last?.author == .assistant ? last?.id : nil,
                      targetLength: last?.text.count ?? 0,
                      isStreaming: last?.isStreaming ?? false)
        if fresh.count != items.count || fresh.last?.text != items.last?.text
            || fresh.last?.thinking != items.last?.thinking {
            items = fresh
        }
        statusNote = transcript.statusNote
        lastError = transcript.lastError
        let dialogs = transcript.dialogs
        if dialogs.map(\.id) != self.dialogs.map(\.id) {
            self.dialogs = dialogs
        }
        if let instance, instance.state == .idle { isSending = false }
        // Los avisos de las extensiones vienen del transcript, que es quien los recibe.
        let statuses = transcript.extensionStatuses
        if statuses.map(\.text) != extensionStatuses.map(\.text) {
            extensionStatuses = statuses
        }
    }

    // MARK: Configuración de Pi

    /// Cuántas conversaciones hay vivas. Es el candado: con procesos activos no se escribe, porque
    /// Pi lee la configuración al arrancar y escribir sería una condición de carrera.
    var activeInstanceCount: Int { agents.count }

    var settingsAreLocked: Bool { activeInstanceCount > 0 }

    func loadSettings() {
        settingsError = nil
        settingsMessage = nil
        let docPath = PiSettingsSchema.discoverDocPath(piExecutable: piPath.map { URL(fileURLWithPath: $0) })
        settingsDocPath = docPath
        settingsSchema = docPath.map { PiSettingsSchema.parse(documentAt: $0) } ?? []
        do {
            let store = try settingsStore ?? PiSettingsStore()
            settingsStore = store
            settingsExternalChange = store.changedOnDisk()
            var values: [String: String] = [:]
            for setting in settingsSchema {
                values[setting.key] = store.displayValue(for: setting.key)
            }
            settingsValues = values
        } catch {
            settingsError = "\(error)"
        }
    }

    /// Aplica solo lo que cambió de verdad. Devuelve un mensaje de error, o `nil` si salió bien.
    func applySettings() -> String? {
        guard let store = settingsStore else { return "No se pudo abrir la configuración de Pi." }
        guard !settingsAreLocked else {
            return "Hay \(activeInstanceCount) conversación(es) activa(s). Esperá a que se liberen."
        }
        var changes: [String: Any?] = [:]
        for setting in settingsSchema {
            let current = store.displayValue(for: setting.key)
            guard let edited = settingsValues[setting.key], edited != current else { continue }
            changes[setting.key] = Self.jsonValue(from: edited, kind: setting.kind)
        }
        guard !changes.isEmpty else {
            settingsMessage = "No hay cambios para aplicar."
            return nil
        }
        do {
            try store.apply(changes, activeInstances: activeInstanceCount)
            settingsMessage = "Guardado: \(changes.count) ajuste(s). Pi los va a ver en su próxima corrida."
            loadSettings()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Convierte lo que se escribió al tipo que espera Pi.
    static func jsonValue(from text: String, kind: PiSettingsSchema.Kind) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .boolean:
            return ["true", "1", "sí", "si", "yes"].contains(trimmed.lowercased())
        case .number:
            if let integer = Int(trimmed) { return integer }
            return Double(trimmed)
        case .textList:
            let lines = trimmed.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines
        case .enumeration:
            // Un enum puede tener `true`/`false` como opciones: ahí no va como texto.
            if trimmed == "true" { return true }
            if trimmed == "false" { return false }
            return trimmed
        case .text:
            return trimmed.isEmpty ? nil : trimmed
        case .object:
            return nil   // no editable desde acá
        }
    }

    /// Cuántas conversaciones te están necesitando. Es lo que se muestra en la barra.
    var attentionCount: Int { AgentAttention.attentionCount(agents) }

    /// Lo que el panel muestra, ya filtrado.
    var filteredAgents: [InstanceSummary] {
        AgentAttention.filtered(agents, query: agentFilter)
    }

    /// Estado por conversación en el latido anterior. Hace falta porque la app **no observa los
    /// eventos** de las conversaciones que no está mirando: de las del fondo solo conoce la foto.
    private var lastAgentStates: [String: InstanceState] = [:]
    /// Qué ya se avisó, por `clave:motivo`, para no repetir en cada latido.
    private var notified: Set<String> = []

    /// Avisa de lo que la persona no puede ver por sí misma.
    ///
    /// La decisión no se toma acá: se delega en `NotificationPolicy`, que es pura y está verificada.
    private func evaluateNotifications() {
        let states = NotificationPolicy.states(of: agents)
        let transitions = NotificationPolicy.transitions(from: lastAgentStates, to: states)
        // `current` es el nombre de la conversación abierta en el modelo; el diccionario se llama
        // `states` para no taparlo.
        let visible = current?.path ?? pinnedKey
        let active = NSApp.isActive

        // ── Te necesita: lo único que requiere a alguien ─────────────────────
        for agent in agents {
            let mark = "\(agent.sessionKey):needsYou"
            if AgentAttention.needsYou(agent) {
                if NotificationPolicy.shouldNotifyNeedsYou(sessionKey: agent.sessionKey,
                                                           visibleSessionKey: visible,
                                                           appIsActive: active,
                                                           alreadyNotified: notified.contains(mark)) {
                    notified.insert(mark)
                    Notifier.post(title: NotificationPolicy.title(for: .needsYou),
                                  body: describe(agent.sessionKey),
                                  sound: true)
                }
            } else {
                // Se resuelve la espera: la próxima vez que bloquee, vuelve a avisar.
                notified.remove(mark)
            }
        }

        // ── Terminó: solo si no está mirando ─────────────────────────────────
        for change in transitions {
            let mark = "\(change.sessionKey):finished"
            if change.toState == .working || change.toState == .blocked {
                notified.remove(mark)   // volvió a trabajar: la próxima vez avisa de nuevo
                continue
            }
            if NotificationPolicy.shouldNotifyFinished(from: change.fromState,
                                                       to: change.toState,
                                                       appIsActive: active,
                                                       alreadyNotified: notified.contains(mark)) {
                notified.insert(mark)
                Notifier.post(title: NotificationPolicy.title(for: .finished),
                              body: describe(change.sessionKey))
            }
        }

        lastAgentStates = states
    }

    /// Cómo nombrar una conversación en una notificación: su título si se lo conoce, y si no, el nombre
    /// del archivo. Nunca la ruta completa.
    private func describe(_ sessionKey: String) -> String {
        if let session = sessions.first(where: { $0.path == sessionKey }) {
            return session.displayTitle
        }
        return (sessionKey as NSString).lastPathComponent
    }

    func refreshAgents() {
        let fresh = AgentAttention.sorted(supervisor?.snapshot() ?? [])
        // Asignar el mismo contenido igual dispara un redibujado: solo se asigna si cambió.
        let changed = fresh.count != agents.count
            || zip(fresh, agents).contains { $0.differsVisibly(from: $1) }
        if changed { agents = fresh }
        evaluateNotifications()
        // Red de seguridad contra el "se quedó frenado": si el proceso ya no está trabajando pero
        // la UI seguía esperando, se destraba sola. Un run que muere sin `agent_settled` dejaría
        // el botón de detener y las burbujas girando para siempre.
        if isSending, let instance, !instance.state.isBusy {
            isSending = false
            if let note = statusNote, note.hasPrefix("reintento") || note.hasPrefix("compactando") {
                statusNote = nil
            }
            unfreezeStreamingBubbles()
        }
    }

    /// Marca como terminado cualquier globo que siguiera "escribiendo" cuando el proceso ya paró.
    private func unfreezeStreamingBubbles() {
        guard items.contains(where: { $0.isStreaming }) else { return }
        transcript.freezeStreaming()
    }

    private func notifyIfNeeded() {
        guard !NSApp.isActive else { return }
        Notifier.post(title: "Pi terminó", body: current?.displayTitle ?? "Conversación")
    }

    func shutdown() {
        supervisor?.shutdownAll()
    }
}

// MARK: - Adjuntos

enum AttachmentLoader {

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic",
    ]

    static func load(url: URL) -> AttachmentRef? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        guard imageExtensions.contains(ext) else {
            // No se copia ni se inyecta: se referencia la ruta (§7.1).
            return AttachmentRef(fileName: name, path: url.path)
        }
        guard let data = try? Data(contentsOf: url) else {
            return AttachmentRef(fileName: name, path: url.path)
        }
        let mime: String
        switch ext {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "tiff", "tif": mime = "image/tiff"
        default: mime = "image/png"
        }
        return AttachmentRef(fileName: name, path: nil,
                             imageBase64: data.base64EncodedString(), mimeType: mime)
    }
}

// MARK: - Notificaciones

enum Notifier {

    /// Pide permiso una vez al arrancar. Sin bundle no hay notificaciones posibles: cuando la app corre
    /// como binario suelto (las pruebas) esto no hace nada, y está bien que así sea.
    static func requestPermissionIfPossible() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Publica una notificación. `sound` se reserva para lo que **requiere** a la persona: una tarea
    /// que termina no necesita sonar.
    static func post(title: String, body: String, sound: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
