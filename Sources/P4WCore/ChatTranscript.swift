import Foundation

// MARK: - Piezas del chat

/// Un adjunto. Las imágenes viajan en base64 dentro del comando `prompt`; el resto se
/// **referencia por ruta** (§7.1 del plan), que es el idioma nativo de Pi (`@ruta`).
public struct AttachmentRef: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    /// Ruta absoluta. `nil` para imágenes que ya viajaron en base64.
    public let path: String?
    public let imageBase64: String?
    public let mimeType: String?

    public init(id: String = UUID().uuidString, fileName: String, path: String?,
                imageBase64: String? = nil, mimeType: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.imageBase64 = imageBase64
        self.mimeType = mimeType
    }

    public var isImage: Bool { imageBase64 != nil }

    /// Una referencia se puede romper si el archivo se mueve o se borra. Se verifica de nuevo
    /// al mostrarla: nunca se miente con un chip que parece disponible.
    public var stillExists: Bool {
        guard let path else { return true }
        return FileManager.default.fileExists(atPath: path)
    }
}

/// Actividad de una herramienta, como chip expandible.
public struct ToolActivity: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public var argumentSummary: String
    public var output: String
    public var isError: Bool
    public var isRunning: Bool

    public init(id: String, name: String, argumentSummary: String, output: String,
                isError: Bool, isRunning: Bool) {
        self.id = id
        self.name = name
        self.argumentSummary = argumentSummary
        self.output = output
        self.isError = isError
        self.isRunning = isRunning
    }

    /// Etiqueta humana para el chip. No se muestra JSON crudo.
    public var label: String {
        switch name {
        case "bash": return isRunning ? "ejecutando comando…" : "comando"
        case "read": return isRunning ? "leyendo archivo…" : "leyó archivo"
        case "write": return isRunning ? "escribiendo archivo…" : "escribió archivo"
        case "edit": return isRunning ? "editando archivo…" : "editó archivo"
        case "grep": return isRunning ? "buscando…" : "búsqueda"
        case "find", "ls": return isRunning ? "listando…" : "listado"
        default: return isRunning ? "\(name)…" : name
        }
    }
}

/// Un mensaje del chat. Es la misma forma para el stream en vivo y para el histórico
/// leído del `.jsonl`, así la UI tiene un solo renderizador (Fase 3).
public struct ChatItem: Sendable, Identifiable {
    public enum Author: String, Sendable { case user, assistant, notice }

    /// Cómo quedó encolado un mensaje enviado mientras Pi trabajaba. Espeja el estándar de Pi:
    /// `Enter` encola una guía (steering), `Alt+Enter` un seguimiento (follow-up).
    public enum Queued: String, Sendable {
        case steering
        case followUp

        public var label: String {
            switch self {
            case .steering: return "en cola · guía"
            case .followUp: return "en cola · seguimiento"
            }
        }
    }

    public let id: String
    public let author: Author
    public var text: String
    /// Cadena de razonamiento. Es un bloque estructurado, no etiquetas dentro del texto (§7.1).
    public var thinking: String
    public var tools: [ToolActivity]
    public var attachments: [AttachmentRef]
    public var isStreaming: Bool
    /// `nil` cuando ya fue entregado (o nunca se encoló).
    public var queued: Queued?
    public var errored: Bool
    public var errorMessage: String?
    public var timestamp: Date

    public init(id: String = UUID().uuidString, author: Author, text: String = "",
                thinking: String = "", tools: [ToolActivity] = [],
                attachments: [AttachmentRef] = [], isStreaming: Bool = false,
                queued: Queued? = nil,
                errored: Bool = false, errorMessage: String? = nil,
                timestamp: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.thinking = thinking
        self.tools = tools
        self.attachments = attachments
        self.isStreaming = isStreaming
        self.queued = queued
        self.errored = errored
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tools.isEmpty
    }
}

// MARK: - Transcript en vivo

/// Construye el chat a partir del stream de eventos. No inventa nada: cada campo viene de
/// un evento, y el contenido autoritativo de `*_end` / `message_end` siempre gana sobre lo
/// reconstruido con deltas.
public final class LiveTranscript: @unchecked Sendable {

    private let lock = NSLock()
    private var _items: [ChatItem] = []
    private var _statusNote: String?
    private var _errored = false
    private var _errorMessage: String?
    private var _pendingDialogs: [DialogRequest] = []
    /// Estado que reportan las extensiones, por clave. Es lo que Pi muestra en su pie: por ejemplo
    /// `cache → "Cache 97.3%"`. Se conserva el orden de llegada porque el orden es información.
    private var _extensionStatuses: [(key: String, text: String)] = []
    /// Id del globo del asistente que pertenece al run **en vivo**.
    ///
    /// Es la pieza que separa "seguir escribiendo en el mismo globo" de "empezar uno nuevo".
    /// Sin esto, los eventos de un run nuevo se pegaban a la última respuesta cargada del archivo.
    private var _liveAssistantID: String?

    /// Texto y pensamiento **por índice de bloque**.
    ///
    /// Es la causa del "se corta la respuesta": una respuesta puede venir partida en varios bloques
    /// (texto → herramienta → más texto). Al cerrar cada bloque, Pi manda el contenido autoritativo
    /// **de ese bloque**, así que reemplazar el texto del globo lo borraba todo menos el último
    /// pedazo. Guardando por índice y uniendo en orden, nada se pierde.
    /// Orden de llegada de los mensajes encolados, para saber cuál se entregó primero.
    private var _queuedUserIDs: [String] = []

    private var liveTextBlocks: [Int: String] = [:]
    private var liveThinkingBlocks: [Int: String] = [:]

    /// Se llama en cualquier cola cuando cambia algo. La UI debe saltar al hilo principal.
    public var onChange: (() -> Void)?

    public init() {}

    public var items: [ChatItem] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    public var statusNote: String? {
        lock.lock(); defer { lock.unlock() }
        return _statusNote
    }

    public var dialogs: [DialogRequest] {
        lock.lock(); defer { lock.unlock() }
        return _pendingDialogs
    }

    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _errorMessage
    }

    /// Reemplaza el contenido por el de una conversación existente.
    ///
    /// Antepone lo que se cargó del historial más viejo. El orden del archivo manda: lo viejo va arriba.
    public func prependItems(_ older: [ChatItem]) {
        guard !older.isEmpty else { return }
        lock.lock()
        _items.insert(contentsOf: older, at: 0)
        lock.unlock()
        onChange?()
    }

    /// El transcript es **la única fuente de la lista que se muestra**: si la historia y los
    /// eventos en vivo vivieran en dos listas distintas, cualquier evento posterior pisaría lo
    /// cargado del archivo. Ese fue exactamente el bug de "abre pero no aparece nada".
    public func replaceItems(_ newItems: [ChatItem]) {
        lock.lock()
        _items = newItems
        _statusNote = nil
        _errored = newItems.contains { $0.errored }
        _errorMessage = newItems.reversed().compactMap(\.errorMessage).first
        _pendingDialogs = []
        _liveAssistantID = nil
        lock.unlock()
        onChange?()
    }

    public func reset() {
        lock.lock()
        _items = []
        _liveAssistantID = nil
        _statusNote = nil
        _errored = false
        _errorMessage = nil
        _pendingDialogs = []
        lock.unlock()
        onChange?()
    }

    /// Agrega el mensaje del usuario. El texto que se muestra ya incluye las rutas de los
    /// adjuntos referenciados, que es lo que efectivamente se le envió a Pi.
    @discardableResult
    public func appendUser(text: String, attachments: [AttachmentRef] = [],
                           queued: ChatItem.Queued? = nil) -> String {
        let item = ChatItem(author: .user, text: text, attachments: attachments, queued: queued)
        lock.lock()
        _items.append(item)
        if queued != nil { _queuedUserIDs.append(item.id) }
        _errored = false
        _errorMessage = nil
        lock.unlock()
        onChange?()
        return item.id
    }

    public func appendNotice(_ text: String, errored: Bool = false) {
        let item = ChatItem(author: .notice, text: text, errored: errored,
                            errorMessage: errored ? text : nil)
        lock.lock()
        _items.append(item)
        lock.unlock()
        onChange?()
    }

    public func apply(_ event: PiEvent) {
        lock.lock()
        switch event {
        case .messageStart, .delta, .blockEnd, .messageEnd:
            applyContent(event)
        case .toolExecutionStart, .toolExecutionUpdate, .toolExecutionEnd:
            applyTool(event)
        case .queueChanged, .agentStart, .agentSettled, .retryStarted, .retryFinished,
             .compactionStart, .compactionEnd, .thinkingLevelChanged:
            applyLifecycle(event)
        case .uiDialog, .uiDialogResolved, .extensionError, .uiNotice:
            applyUI(event)
        default:
            break
        }
        lock.unlock()
        onChange?()
    }

    // Los cuatro helpers de abajo se llaman **con el lock tomado**.

    private func applyContent(_ event: PiEvent) {
        switch event {
        case .messageStart(let role):
            if role == "assistant" { startAssistant() }

        case .delta(let delta, _):
            ensureAssistant()
            switch delta.kind {
            case .text:
                liveTextBlocks[delta.contentIndex, default: ""] += delta.text
                _items[_items.count - 1].text = Self.joinBlocks(liveTextBlocks)
            case .thinking:
                liveThinkingBlocks[delta.contentIndex, default: ""] += delta.text
                _items[_items.count - 1].thinking = Self.joinBlocks(liveThinkingBlocks)
            case .toolCallArguments: break
            }
            _items[_items.count - 1].isStreaming = true

        case .blockEnd(let block):
            // El contenido autoritativo reemplaza lo reconstruido **solo de ese bloque**.
            ensureAssistant()
            switch block.kind {
            case .text:
                liveTextBlocks[block.contentIndex] = block.text
                _items[_items.count - 1].text = Self.joinBlocks(liveTextBlocks)
            case .thinking:
                liveThinkingBlocks[block.contentIndex] = block.text
                _items[_items.count - 1].thinking = Self.joinBlocks(liveThinkingBlocks)
            }

        case .messageEnd(let role, let text, let thinking, let stopReason, let error, _):
            guard role == "assistant" else { break }
            ensureAssistant()
            if !text.isEmpty { _items[_items.count - 1].text = text }
            if !thinking.isEmpty { _items[_items.count - 1].thinking = thinking }
            // El mensaje completo es la verdad final: los bloques ya no hacen falta.
            liveTextBlocks.removeAll()
            liveThinkingBlocks.removeAll()
            _items[_items.count - 1].isStreaming = false
            guard stopReason == "error" else { break }
            // Una corrida que falla no se muestra como exitosa.
            _errored = true
            _errorMessage = error ?? "el proveedor devolvió un error"
            _items[_items.count - 1].errored = true
            _items[_items.count - 1].errorMessage = _errorMessage

        default:
            break
        }
    }

    private func applyTool(_ event: PiEvent) {
        switch event {
        case .toolExecutionStart(let id, let name, let summary):
            ensureAssistant()
            _items[_items.count - 1].tools.append(
                ToolActivity(id: id, name: name, argumentSummary: summary,
                             output: "", isError: false, isRunning: true)
            )

        case .toolExecutionUpdate(let id, _, let partial):
            guard !partial.isEmpty else { break }
            updateTool(id: id) { $0.output = partial }

        case .toolExecutionEnd(let id, _, let isError, let output):
            updateTool(id: id) { tool in
                tool.isRunning = false
                tool.isError = isError
                if !output.isEmpty { tool.output = output }
            }

        default:
            break
        }
    }

    private func applyLifecycle(_ event: PiEvent) {
        switch event {
        case .queueChanged(let steering, let followUp):
            // `queue_update` trae la cola completa pendiente. Cuando baja la cuenta, los primeros
            // ya se entregaron: se les saca la marca de "en cola".
            var pending = steering + followUp
            while !_queuedUserIDs.isEmpty, _queuedUserIDs.count > pending {
                let delivered = _queuedUserIDs.removeFirst()
                if let index = _items.firstIndex(where: { $0.id == delivered }) {
                    _items[index].queued = nil
                }
                pending = steering + followUp
                break
            }

        case .agentStart:
            // Ojo: `agent_start` puede llegar antes o después de `message_start`. Por eso acá NO
            // se fuerza un globo nuevo: se reutiliza el del run en vivo si ya existe. El globo
            // nuevo del turno siguiente lo garantiza `agentSettled`, que suelta el id al cerrar.
            ensureAssistant()
            _items[_items.count - 1].isStreaming = true
            _statusNote = nil

        case .agentSettled:
            for index in _items.indices {
                _items[index].isStreaming = false
                _items[index].queued = nil     // el run terminó: ya no queda nada pendiente
            }
            _queuedUserIDs.removeAll()
            _liveAssistantID = nil
            liveTextBlocks.removeAll()
            liveThinkingBlocks.removeAll()
            _statusNote = nil

        case .retryStarted(let attempt, let maxAttempts, let error):
            _statusNote = "reintento \(attempt)/\(maxAttempts) — \(error)"

        case .retryFinished(let success, let finalError):
            if !success {
                _errored = true
                _errorMessage = finalError ?? _errorMessage ?? "se agotaron los reintentos"
            }
            _statusNote = nil

        case .thinkingLevelChanged(let level):
            _statusNote = "nivel de thinking: \(level)"

        case .compactionStart(let reason):
            _statusNote = "compactando contexto (\(reason ?? "?"))…"

        case .compactionEnd(let reason, let aborted, let error, _, _, _):
            if let error {
                appendNoticeLocked("Compactación falló: \(error)", errored: true)
            } else if aborted {
                appendNoticeLocked("Compactación cancelada (\(reason ?? "?")).", errored: false)
            }
            _statusNote = nil

        default:
            break
        }
    }

    private func applyUI(_ event: PiEvent) {
        switch event {
        case .uiDialog(let dialog):
            _pendingDialogs.append(dialog)

        case .uiDialogResolved(let id):
            _pendingDialogs.removeAll { $0.id == id }

        case .extensionError(let message):
            appendNoticeLocked("Error de extensión: \(message)", errored: true)

        case .uiNotice(_, let method, let statusKey, let text):
            guard method == "setStatus", let statusKey else {
                // `notify` y compañía son avisos sueltos: si traen texto, se muestran una vez.
                if let text, !text.isEmpty { appendNoticeLocked(TerminalText.clean(text), errored: false) }
                break
            }
            let cleaned = text.map(TerminalText.clean) ?? ""
            // Se actualiza **en su lugar**, no se manda al final: la tasa de acierto se actualiza en cada
            // turno, y si el texto saltara de posición en la barra sería un parpadeo constante.
            let existing = _extensionStatuses.firstIndex { $0.key == statusKey }
            // Un `setStatus` sin texto **borra** ese estado: así lo usa la extensión al cerrar la sesión.
            if cleaned.isEmpty {
                if let existing { _extensionStatuses.remove(at: existing) }
            } else if let existing {
                _extensionStatuses[existing] = (key: statusKey, text: cleaned)
            } else {
                _extensionStatuses.append((key: statusKey, text: cleaned))
            }

        default:
            break
        }
    }

    /// Lo que las extensiones están reportando ahora, en orden de llegada.
    public var extensionStatuses: [(key: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        return _extensionStatuses
    }

    /// Mensajes del usuario que siguen esperando turno.
    public var queuedItems: [ChatItem] {
        lock.lock(); defer { lock.unlock() }
        return _items.filter { $0.queued != nil }
    }

    /// Cierra cualquier globo que siguiera marcado como "escribiendo". Red de seguridad para
    /// cuando un run muere sin emitir `agent_settled`.
    public func freezeStreaming() {
        lock.lock()
        var changed = false
        for index in _items.indices where _items[index].isStreaming {
            _items[index].isStreaming = false
            changed = true
        }
        _liveAssistantID = nil
        liveTextBlocks.removeAll()
        liveThinkingBlocks.removeAll()
        lock.unlock()
        if changed { onChange?() }
    }

    /// Saca la marca de "en cola" de todos los mensajes. Se usa al devolverlos al editor.
    public func clearQueued() {
        lock.lock()
        for index in _items.indices { _items[index].queued = nil }
        _queuedUserIDs.removeAll()
        lock.unlock()
        onChange?()
    }

    public func resolveDialog(id: String) {
        lock.lock()
        _pendingDialogs.removeAll { $0.id == id }
        lock.unlock()
        onChange?()
    }

    // MARK: Internos (siempre con el lock tomado)

    /// Arranca un globo nuevo solo si el último no es el del run en vivo.
    private func startAssistant() {
        if let last = _items.last, last.author == .assistant,
           last.id == _liveAssistantID, last.isStreaming {
            return
        }
        appendLiveAssistant()
    }

    private func ensureAssistant() {
        if let last = _items.last, last.author == .assistant, last.id == _liveAssistantID {
            return
        }
        appendLiveAssistant()
    }

    private func appendLiveAssistant() {
        let item = ChatItem(author: .assistant, isStreaming: true)
        _items.append(item)
        _liveAssistantID = item.id
        liveTextBlocks.removeAll()
        liveThinkingBlocks.removeAll()
    }

    /// Une los bloques en orden de índice, sin dejar huecos por bloques vacíos.
    private static func joinBlocks(_ blocks: [Int: String]) -> String {
        blocks.keys.sorted()
            .compactMap { blocks[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func updateTool(id: String, _ mutate: (inout ToolActivity) -> Void) {
        for itemIndex in _items.indices.reversed() {
            if let toolIndex = _items[itemIndex].tools.firstIndex(where: { $0.id == id }) {
                mutate(&_items[itemIndex].tools[toolIndex])
                return
            }
        }
    }

    /// Se llama **con el lock tomado**. El público `appendNotice` es el que lockea.
    private func appendNoticeLocked(_ text: String, errored: Bool) {
        _items.append(ChatItem(author: .notice, text: text, errored: errored,
                               errorMessage: errored ? text : nil))
    }
}
