import Foundation

/// Uso reportado por el proveedor. Los campos vienen del bloque `usage` del stream.
public struct TokenUsage: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    /// Tokens de razonamiento. No se esconden: el pensamiento se paga como salida.
    public var reasoning = 0
    public var total = 0
    public var costTotal: Double = 0

    public init() {}

    public init(json: [String: Any]) {
        input = json["input"] as? Int ?? 0
        output = json["output"] as? Int ?? 0
        cacheRead = json["cacheRead"] as? Int ?? 0
        cacheWrite = json["cacheWrite"] as? Int ?? 0
        reasoning = json["reasoning"] as? Int ?? 0
        total = json["totalTokens"] as? Int ?? (input + output)
        if let cost = json["cost"] as? [String: Any] {
            costTotal = (cost["total"] as? Double) ?? Double(cost["total"] as? Int ?? 0)
        }
    }

    public var summary: String {
        "in \(input) · out \(output) · cache \(cacheRead)/\(cacheWrite) · razonamiento \(reasoning)"
    }
}

/// Un delta de contenido dentro de `message_update`.
public struct ContentDelta: Sendable, Equatable {
    public enum Kind: Sendable { case text, thinking, toolCallArguments }
    public let kind: Kind
    public let contentIndex: Int
    public let text: String

    public init(kind: Kind, contentIndex: Int, text: String) {
        self.kind = kind
        self.contentIndex = contentIndex
        self.text = text
    }
}

/// Bloque de contenido cerrado, ya autoritativo (reemplaza lo reconstruido por deltas).
public struct ContentBlockEnd: Sendable, Equatable {
    public enum Kind: Sendable { case text, thinking }
    public let kind: Kind
    public let contentIndex: Int
    public let text: String

    public init(kind: Kind, contentIndex: Int, text: String) {
        self.kind = kind
        self.contentIndex = contentIndex
        self.text = text
    }
}

/// Pedido de interacción de una extensión. Los cuatro métodos de diálogo exigen respuesta
/// con el mismo `id`; el resto son avisos.
public struct DialogRequest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case select, confirm, input, editor
    }

    public let id: String
    public let method: String
    public let title: String?
    public let message: String?
    public let placeholder: String?
    public let options: [String]
    public let timeoutMs: Int?

    public var kind: Kind? { Kind(rawValue: method) }

    /// Texto que se muestra como encabezado.
    public var prompt: String {
        [title, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public init(id: String, method: String, title: String?, message: String?,
                placeholder: String?, options: [String], timeoutMs: Int?) {
        self.id = id
        self.method = method
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.options = options
        self.timeoutMs = timeoutMs
    }
}

/// Evento tipado del stream de Pi.
///
/// Se decodifica **por whitelist explícita**: lo que no conocemos se conserva como
/// `.other(type:)` en vez de romper el parser. Pi agrega eventos con el tiempo y P4W no
/// debe caerse cuando eso pase.
public enum PiEvent: Sendable {
    /// El **nombre del tipo** de evento, sin ningún dato adentro.
    ///
    /// Es lo que permite registrar que algo pasó sin registrar el algo: el log dice `rpc.evento tipo=tool_call`
    /// y nunca toca el contenido. El `switch` es exhaustivo, así que agregar un evento nuevo **obliga** a
    /// nombrarlo — no se puede olvidar.
    public var kindName: String {
        switch self {
        case .messageStart: return "message_start"
        case .delta: return "delta"
        case .blockEnd: return "block_end"
        case .messageEnd: return "message_end"
        case .toolCallStarted: return "tool_call_started"
        case .toolCallArguments: return "tool_call_arguments"
        case .toolCallCompleted: return "tool_call_completed"
        case .toolInput: return "tool_input"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .agentSettled: return "agent_settled"
        case .thinkingLevelChanged: return "thinking_level_changed"
        case .sessionInfoChanged: return "session_info_changed"
        case .compactionStart: return "compaction_start"
        case .compactionEnd: return "compaction_end"
        case .retryStarted: return "retry_started"
        case .retryFinished: return "retry_finished"
        case .extensionError: return "extension_error"
        case .queueChanged: return "queue_changed"
        case .uiDialog: return "ui_dialog"
        case .uiNotice: return "ui_notice"
        case .uiDialogResolved: return "ui_dialog_resolved"
        case .bashExecutionOutput: return "bash_execution_output"
        case .other: return "other"
        }
    }

    case messageStart(role: String?)
    case delta(ContentDelta, usage: TokenUsage?)
    case blockEnd(ContentBlockEnd)
    case messageEnd(role: String?, text: String, thinking: String, stopReason: String?,
                    error: String?, usage: TokenUsage?)
    case toolCallStarted(id: String, name: String, argumentSummary: String)
    case toolCallArguments(id: String, name: String, chunk: String)
    case toolCallCompleted(id: String, name: String)
    case toolInput(contentIndex: Int, id: String, name: String)

    case toolExecutionStart(id: String, name: String, argumentSummary: String)
    case toolExecutionUpdate(id: String, name: String, partial: String)
    case toolExecutionEnd(id: String, name: String, isError: Bool, output: String)

    case turnStart
    case turnEnd
    case agentStart
    case agentEnd
    case agentSettled

    case thinkingLevelChanged(String)
    /// El nombre visible de la sesión cambió. Sirve para refrescar el título en el explorador.
    case sessionInfoChanged(name: String?)
    case compactionStart(reason: String?)
    case compactionEnd(reason: String?, aborted: Bool, error: String?, willRetry: Bool,
                       tokensBefore: Int?, tokensAfter: Int?)
    /// Reintento automático de un turno. `error` es el motivo reportado por el proveedor.
    case retryStarted(attempt: Int, maxAttempts: Int, error: String)
    case retryFinished(success: Bool, finalError: String?)
    /// Una extensión lanzó una excepción.
    case extensionError(message: String)
    case queueChanged(steering: Int, followUp: Int)

    /// Diálogo que **bloquea** al agente esperando respuesta (select/confirm/input/editor).
    case uiDialog(DialogRequest)
    /// Aviso que no bloquea (notify/setStatus/setWidget/setTitle/set_editor_text).
    ///
    /// Lleva su contenido porque no es decorativo: `setStatus` es como una extensión reporta **datos
    /// reales** — por ejemplo la tasa de acierto del caché de prefijo, que es un ahorro medible.
    case uiNotice(id: String, method: String, statusKey: String?, text: String?)
    case uiDialogResolved(id: String)

    case bashExecutionOutput(id: String?, delta: String, isError: Bool)

    /// Evento desconocido. Se registra y se ignora; nunca rompe el stream.
    case other(type: String)

    /// Métodos de `extension_ui_request` que dejan al agente esperando input.
    /// Verificado contra `docs/rpc-extension-ui.md`: son exactamente estos cuatro.
    public static let blockingDialogMethods: Set<String> = ["select", "confirm", "input", "editor"]
}

extension PiEvent {

    /// Motivo de parada del mensaje del asistente. `stopReason == "error"` significa que la
    /// corrida **falló** y la UI no debe mostrarla como exitosa.
    public static func stopReason(_ message: [String: Any]?) -> String? {
        message?["stopReason"] as? String
    }

    public static func errorMessage(_ message: [String: Any]?) -> String? {
        message?["errorMessage"] as? String
    }

    public static func decode(_ payload: [String: Any]) -> PiEvent {
        switch payload["type"] as? String ?? "" {
        case "message_start", "message_update", "message_end":
            return decodeMessageEvent(payload)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            return decodeToolExecutionEvent(payload)
        case "turn_start", "turn_end", "agent_start", "agent_end", "agent_settled",
             "thinking_level_changed", "session_info_changed", "compaction_start", "compaction_end",
             "auto_retry_start", "auto_retry_end", "queue_update":
            return decodeLifecycleEvent(payload)
        case "extension_ui_request", "extension_error", "bash_execution_update":
            return decodeUIEvent(payload)
        default:
            // Whitelist explícita: lo que no conocemos se conserva como `.other`.
            // Pi agrega eventos con el tiempo y P4W no debe caerse cuando eso pase.
            return .other(type: payload["type"] as? String ?? "")
        }
    }

    private static func decodeMessageEvent(_ payload: [String: Any]) -> PiEvent {
        let type = payload["type"] as? String ?? ""
        let usage = (payload["usage"] as? [String: Any]).map(TokenUsage.init(json:))

        switch type {
        case "message_start":
            let role = (payload["message"] as? [String: Any])?["role"] as? String
            return .messageStart(role: role)

        case "message_update":
            return decodeUpdate(payload, usage: usage)

        case "message_end":
            let message = payload["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            let text = Self.joinText(blocks, type: "text", key: "text")
            let thinking = Self.joinText(blocks, type: "thinking", key: "thinking")
            let role = message?["role"] as? String
            let messageUsage = (message?["usage"] as? [String: Any]).map(TokenUsage.init(json:)) ?? usage
            return .messageEnd(role: role, text: text, thinking: thinking,
                               stopReason: Self.stopReason(message), error: Self.errorMessage(message),
                               usage: messageUsage)

        default:
            return .other(type: type)
        }
    }

    private static func decodeToolExecutionEvent(_ payload: [String: Any]) -> PiEvent {
        let id = payload["toolCallId"] as? String ?? ""
        let name = payload["toolName"] as? String ?? "?"

        switch payload["type"] as? String ?? "" {
        case "tool_execution_start":
            return .toolExecutionStart(
                id: id,
                name: name,
                argumentSummary: Self.summarize(arguments: payload["args"])
            )

        case "tool_execution_update":
            return .toolExecutionUpdate(
                id: id,
                name: name,
                partial: Self.extractContentText(payload["partialResult"])
            )

        default:
            return .toolExecutionEnd(
                id: id,
                name: name,
                isError: payload["isError"] as? Bool ?? false,
                output: Self.extractContentText(payload["result"])
            )
        }
    }

    private static func decodeLifecycleEvent(_ payload: [String: Any]) -> PiEvent {
        switch payload["type"] as? String ?? "" {
        case "turn_start": return .turnStart
        case "turn_end": return .turnEnd
        case "agent_start": return .agentStart
        case "agent_end": return .agentEnd
        case "agent_settled": return .agentSettled

        case "thinking_level_changed":
            return .thinkingLevelChanged(payload["level"] as? String ?? "?")

        case "session_info_changed":
            return .sessionInfoChanged(name: payload["name"] as? String)

        case "compaction_start":
            return .compactionStart(reason: payload["reason"] as? String)

        case "compaction_end":
            let result = payload["result"] as? [String: Any]
            return .compactionEnd(
                reason: payload["reason"] as? String,
                aborted: payload["aborted"] as? Bool ?? false,
                error: payload["errorMessage"] as? String,
                willRetry: payload["willRetry"] as? Bool ?? false,
                tokensBefore: result?["tokensBefore"] as? Int,
                tokensAfter: result?["estimatedTokensAfter"] as? Int
            )

        case "auto_retry_start":
            return .retryStarted(
                attempt: payload["attempt"] as? Int ?? 1,
                maxAttempts: payload["maxAttempts"] as? Int ?? 1,
                error: payload["errorMessage"] as? String ?? "error sin mensaje"
            )

        case "auto_retry_end":
            return .retryFinished(
                success: payload["success"] as? Bool ?? false,
                finalError: payload["finalError"] as? String
            )

        default:
            return .queueChanged(
                steering: (payload["steering"] as? [Any])?.count ?? 0,
                followUp: (payload["followUp"] as? [Any])?.count ?? 0
            )
        }
    }

    private static func decodeUIEvent(_ payload: [String: Any]) -> PiEvent {
        switch payload["type"] as? String ?? "" {
        case "extension_ui_request":
            let id = payload["id"] as? String ?? ""
            let method = payload["method"] as? String ?? ""
            guard PiEvent.blockingDialogMethods.contains(method) else {
                // Cada método de aviso nombra su contenido distinto.
                let key = payload["statusKey"] as? String
                let text = (payload["statusText"] as? String)
                    ?? (payload["message"] as? String)
                    ?? (payload["title"] as? String)
                return .uiNotice(id: id, method: method, statusKey: key, text: text)
            }
            return .uiDialog(DialogRequest(
                id: id,
                method: method,
                title: payload["title"] as? String,
                message: payload["message"] as? String,
                placeholder: payload["placeholder"] as? String,
                options: payload["options"] as? [String] ?? [],
                timeoutMs: payload["timeout"] as? Int
            ))

        case "extension_error":
            let message = payload["errorMessage"] as? String
                ?? payload["message"] as? String
                ?? "error de extensión"
            return .extensionError(message: message)

        default:
            return .bashExecutionOutput(
                id: payload["id"] as? String,
                delta: (payload["delta"] as? String) ?? (payload["chunk"] as? String) ?? "",
                isError: payload["isError"] as? Bool ?? false
            )
        }
    }

    private static func decodeUpdate(_ payload: [String: Any], usage: TokenUsage?) -> PiEvent {
        guard let inner = payload["assistantMessageEvent"] as? [String: Any],
              let innerType = inner["type"] as? String else {
            return .other(type: "message_update")
        }
        let contentIndex = inner["contentIndex"] as? Int ?? 0

        switch innerType {
        case "text_start", "thinking_start":
            return .other(type: innerType)

        case "text_delta":
            return .delta(ContentDelta(kind: .text, contentIndex: contentIndex,
                                       text: inner["delta"] as? String ?? ""), usage: usage)
        case "thinking_delta":
            return .delta(ContentDelta(kind: .thinking, contentIndex: contentIndex,
                                       text: inner["delta"] as? String ?? ""), usage: usage)

        case "text_end":
            return .blockEnd(ContentBlockEnd(kind: .text, contentIndex: contentIndex,
                                             text: inner["content"] as? String ?? ""))
        case "thinking_end":
            return .blockEnd(ContentBlockEnd(kind: .thinking, contentIndex: contentIndex,
                                             text: inner["content"] as? String ?? ""))

        case "toolcall_start":
            return .toolInput(contentIndex: contentIndex,
                              id: inner["id"] as? String ?? "",
                              name: inner["toolName"] as? String ?? "?")
        case "toolcall_delta":
            return .toolCallArguments(id: "", name: "", chunk: inner["delta"] as? String ?? "")
        case "toolcall_end":
            let call = inner["toolCall"] as? [String: Any]
            return .toolCallCompleted(id: call?["id"] as? String ?? "",
                                      name: call?["name"] as? String ?? "?")

        case "start", "done", "error":
            // Pi los traduce a message_start/message_end; no se emiten sueltos en RPC.
            return .other(type: "message_update/\(innerType)")

        default:
            return .other(type: "message_update/\(innerType)")
        }
    }

    private static func joinText(_ blocks: [[String: Any]], type: String, key: String) -> String {
        blocks.compactMap { block -> String? in
            guard block["type"] as? String == type else { return nil }
            return block[key] as? String
        }.joined()
    }

    /// `result` y `partialResult` tienen forma `{content: [{type: "text", text: "…"}], details: {}}`.
    static func extractContentText(_ value: Any?) -> String {
        guard let object = value as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    /// Resumen corto de los argumentos de una herramienta, para el chip de la UI.
    /// No se muestra el JSON crudo: se muestra lo que un humano necesita.
    static func summarize(arguments: Any?) -> String {
        guard let arguments = arguments as? [String: Any] else { return "" }
        for key in ["command", "path", "file_path", "pattern", "query", "url"] {
            if let value = arguments[key] as? String {
                return value.count > 120 ? String(value.prefix(120)) + "…" : value
            }
        }
        if let keys = arguments.keys.min() { return keys }
        return ""
    }
}
