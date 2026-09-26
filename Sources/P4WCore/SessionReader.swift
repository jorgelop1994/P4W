import Foundation

/// Lee una conversación guardada y la convierte en los mismos `ChatItem` que produce el stream
/// en vivo. Así la UI tiene **un solo renderizador** para histórico y para vivo.
///
/// Reconstruye la **rama activa** recorriendo `parentId` hacia atrás desde la última entrada,
/// no el orden del archivo: Pi guarda un árbol y el orden de escritura puede contener ramas
/// abandonadas (§9 del plan).
public enum SessionReader {

    /// Techo de lectura. Una sesión puede pesar decenas de MB y la UI no necesita todo para
    /// mostrar la conversación; si se recorta, se avisa en vez de mentir con un historial parcial.
    public static let maxReadBytes = 16 * 1024 * 1024

    public struct Result: Sendable {
        public let items: [ChatItem]
        public let truncated: Bool
        public let totalBytes: Int64
    }

    public static func load(path: String) -> Result {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let total: Int64 = (attributes?[.size] as? Int64) ?? 0

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Result(items: [], truncated: false, totalBytes: total)
        }
        defer { try? handle.close() }

        var truncated = false
        var data: Data
        if total > Int64(maxReadBytes) {
            try? handle.seek(toOffset: UInt64(total) - UInt64(maxReadBytes))
            data = (try? handle.readToEnd()) ?? Data()
            truncated = true
            // Descartar la primera línea: llegó partida por el recorte.
            if let firstBreak = data.firstIndex(of: 0x0A) {
                data = data[data.index(after: firstBreak)...]
            }
        } else {
            data = (try? handle.readToEnd()) ?? Data()
        }

        return Result(items: items(from: data), truncated: truncated, totalBytes: total)
    }

    /// Extrae **el texto buscable** de una conversación: un renglón por mensaje.
    ///
    /// Se indexa lo que alguien querría encontrar después: lo que escribió la persona, lo que
    /// respondió Pi y lo que Pi pensó. Las llamadas a herramientas y sus salidas quedan afuera a
    /// propósito: son ruido para una búsqueda y multiplican el tamaño del índice.
    ///
    /// También devuelve el nombre de la sesión, que es la otra cosa que se busca por texto.
    public static func searchableText(path: String) -> (rows: [(role: String, body: String)], name: String?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let total: Int64 = (attributes?[.size] as? Int64) ?? 0
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], nil) }
        defer { try? handle.close() }

        var truncated = false
        var data: Data
        if total > Int64(maxReadBytes) {
            try? handle.seek(toOffset: UInt64(total) - UInt64(maxReadBytes))
            data = (try? handle.readToEnd()) ?? Data()
            truncated = true
            if let firstBreak = data.firstIndex(of: 0x0A) {
                data = data[data.index(after: firstBreak)...]
            }
        } else {
            data = (try? handle.readToEnd()) ?? Data()
        }
        _ = truncated

        var rows: [(role: String, body: String)] = []
        var name: String?
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            if type == "session_info", let value = object["name"] as? String, !value.isEmpty {
                name = value
                continue
            }
            guard type == "message", let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []

            let text = blocks.compactMap { block -> String? in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
            let thinking = blocks.compactMap { block -> String? in
                block["type"] as? String == "thinking" ? block["thinking"] as? String : nil
            }.joined(separator: "\n")

            // Tope por mensaje: buscar sirve casi siempre por el principio del mensaje, y sin tope
            // el índice se lleva respuestas enteras de 16 MB. Medido: tokenizar todo eso domina el
            // costo del indexado inicial.
            if !text.isEmpty { rows.append((role: role, body: capped(text))) }
            if !thinking.isEmpty { rows.append((role: "pensamiento", body: capped(thinking))) }
        }
        return (rows, name)
    }

    /// Cuánto texto de cada mensaje entra al índice.
    public static let maxIndexedCharsPerMessage = 4_000

    private static func capped(_ text: String) -> String {
        text.count <= maxIndexedCharsPerMessage
            ? text
            : String(text.prefix(maxIndexedCharsPerMessage))
    }

    /// Una ventana de conversación leída **desde el final**.
    ///
    /// Es la respuesta al problema de abrir una conversación grande: leer y parsear el archivo entero
    /// antes de mostrar nada hace que la ventana parezca colgada. Se lee el tramo final, se muestra ya,
    /// y lo anterior se pide si hace falta.
    public struct Window: Sendable {
        public let items: [ChatItem]
        /// Offset donde empieza esta ventana. Sirve para pedir la anterior.
        public let startOffset: Int64
        public let hasMore: Bool
    }

    /// Cuánto se lee de una vez. Suficiente para llenar la pantalla varias veces.
    public static let windowBytes = 2 * 1024 * 1024
    /// Cuántos mensajes trae la primera ventana. Cada mensaje puede tener decenas de bloques de
    /// markdown, así que esto se multiplica por la cantidad de vistas: 40 llena la pantalla varias
    /// veces y mantiene el árbol de vistas chico. Lo anterior se pide con "cargar anteriores".
    public static let windowItems = 40

    /// Lee el **final** de la conversación. Es lo primero que se muestra al abrir.
    public static func loadTail(path: String,
                                limit: Int = windowItems,
                                maxBytes: Int = windowBytes) -> Window {
        let size = fileSize(path)
        return window(path: path, endingAt: size, limit: limit, maxBytes: maxBytes)
    }

    /// Lee el tramo anterior al offset dado. Es lo que se pide al subir.
    public static func loadBefore(path: String, before offset: Int64,
                                  limit: Int = windowItems, maxBytes: Int = windowBytes) -> Window {
        window(path: path, endingAt: offset, limit: limit, maxBytes: maxBytes)
    }

    private static func fileSize(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    /// Lee un tramo terminado en `endingAt` y devuelve los últimos `limit` items.
    private static func window(path: String, endingAt: Int64,
                               limit: Int, maxBytes: Int) -> Window {
        guard endingAt > 0, let handle = FileHandle(forReadingAtPath: path) else {
            return Window(items: [], startOffset: 0, hasMore: false)
        }
        defer { try? handle.close() }

        let start = max(0, endingAt - Int64(maxBytes))
        try? handle.seek(toOffset: UInt64(start))
        guard var data = try? handle.read(upToCount: Int(endingAt - start)) else {
            return Window(items: [], startOffset: 0, hasMore: false)
        }

        var firstLineOffset = start
        if start > 0 {
            // La primera línea llegó cortada: se descarta y se anota dónde empieza la siguiente.
            if let breakIndex = data.firstIndex(of: 0x0A) {
                firstLineOffset = start + Int64(data.distance(from: data.startIndex, to: breakIndex)) + 1
                data = data[data.index(after: breakIndex)...]
            }
        }

        // Se guardan los offsets de cada línea para poder pedir el tramo anterior sin adivinar.
        var entries: [(offset: Int64, object: [String: Any])] = []
        var cursor = firstLineOffset
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            defer { cursor += Int64(line.count) + 1 }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type != "session" else { continue }
            entries.append((cursor, object))
        }

        let kept = entries.suffix(limit)
        let items = buildItems(from: kept.map(\.object))
        let windowStart = kept.first?.offset ?? firstLineOffset
        return Window(items: items,
                      startOffset: windowStart,
                      hasMore: windowStart > 0)
    }

    /// El modelo con el que se estaba trabajando, según el archivo.
    ///
    /// Sirve para que la barra muestre el modelo de la conversación **antes** de despertar el proceso:
    /// abrir una conversación no debería arrancar nada.
    public static func lastModelInfo(path: String) -> (provider: String, modelId: String)? {
        let size = fileSize(path)
        guard size > 0 else { return nil }

        // Primero, la fuente más directa: cada respuesta del asistente guarda con qué modelo se hizo.
        // El último mensaje del archivo es entonces el modelo que se está usando de verdad.
        if let tail = read(path: path, from: max(0, size - 262_144), to: size) {
            var fromMessage: (String, String)?
            var fromChange: (String, String)?
            for line in tail.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "message",
                      let message = object["message"] as? [String: Any] else { continue }
                if message["role"] as? String == "assistant",
                   let provider = message["provider"] as? String,
                   let model = message["model"] as? String {
                    fromMessage = (provider, model)
                }
            }
            if let fromMessage { return fromMessage }
            for line in tail.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "model_change",
                      let provider = object["provider"] as? String,
                      let modelId = object["modelId"] as? String else { continue }
                fromChange = (provider, modelId)
            }
            if let fromChange { return fromChange }
        }

        // Y si el tramo final no dice nada, el principio: `model_change` se escribe al arrancar la
        // sesión, así que en una conversación larga está arriba, no abajo.
        guard let head = read(path: path, from: 0, to: min(size, 262_144)) else { return nil }
        for line in head.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "model_change",
                  let provider = object["provider"] as? String,
                  let modelId = object["modelId"] as? String else { continue }
            return (provider, modelId)
        }
        return nil
    }

    private static func read(path: String, from start: Int64, to end: Int64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(start))
        guard end > start else { return nil }
        return try? handle.read(upToCount: Int(end - start))
    }

    /// Convierte bytes del `.jsonl` en items de chat.
    static func items(from data: Data) -> [ChatItem] {
        var entries: [[String: Any]] = []
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "session" { continue }
            entries.append(object)
        }
        guard !entries.isEmpty else { return [] }

        // Índice por id y recorrido hacia la raíz desde la última entrada con id.
        var byId: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let id = entry["id"] as? String { byId[id] = index }
        }
        var branch: [[String: Any]] = []
        var cursor = entries.count - 1
        var guardCount = 0
        while cursor >= 0, guardCount < entries.count + 1 {
            guardCount += 1
            let entry = entries[cursor]
            branch.append(entry)
            guard let parent = entry["parentId"] as? String, let parentIndex = byId[parent] else { break }
            cursor = parentIndex
        }
        branch.reverse()

        return buildItems(from: branch)
    }

    private static func buildItems(from branch: [[String: Any]]) -> [ChatItem] {
        var items: [ChatItem] = []
        // Para pegar el resultado de una herramienta en el chip que ya se dibujó.
        var toolLocation: [String: (itemIndex: Int, toolIndex: Int)] = [:]

        for entry in branch {
            let type = entry["type"] as? String ?? ""

            if type == "compaction", let tokens = entry["tokensBefore"] as? Int {
                items.append(ChatItem(author: .notice,
                                      text: "Contexto compactado (antes: \(tokens) tokens)."))
                continue
            }
            if type == "custom_message", let text = entry["text"] as? String {
                items.append(ChatItem(author: .notice, text: text))
                continue
            }
            guard type == "message", let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let timestamp = (message["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let blocks = message["content"] as? [[String: Any]] ?? []

            switch role {
            case "user":
                let text = text(of: blocks)
                let images = blocks.filter { $0["type"] as? String == "image" }
                let attachments = images.enumerated().map { index, block in
                    AttachmentRef(fileName: "imagen \(index + 1)", path: nil,
                                  imageBase64: block["data"] as? String,
                                  mimeType: block["mimeType"] as? String)
                }
                guard !text.isEmpty || !attachments.isEmpty else { continue }
                items.append(ChatItem(author: .user, text: text, attachments: attachments,
                                      timestamp: timestamp))

            case "assistant":
                var item = ChatItem(author: .assistant,
                                    text: text(of: blocks),
                                    thinking: thinking(of: blocks),
                                    timestamp: timestamp)
                for block in blocks where block["type"] as? String == "toolCall" {
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "?"
                    let summary = summarize(arguments: block["arguments"])
                    item.tools.append(ToolActivity(id: id, name: name, argumentSummary: summary,
                                                   output: "", isError: false, isRunning: false))
                }
                if let stopReason = message["stopReason"] as? String, stopReason == "error" {
                    item.errored = true
                    item.errorMessage = message["errorMessage"] as? String
                }
                insertAssistant(item, into: &items, toolLocation: &toolLocation)

            case "toolResult":
                guard let callId = message["toolCallId"] as? String,
                      let location = toolLocation[callId],
                      items.indices.contains(location.itemIndex),
                      items[location.itemIndex].tools.indices.contains(location.toolIndex) else { continue }
                let output = text(of: blocks)
                items[location.itemIndex].tools[location.toolIndex].output = output
                items[location.itemIndex].tools[location.toolIndex].isError = message["isError"] as? Bool ?? false

            case "bashExecution":
                let command = message["command"] as? String ?? "comando"
                let output = message["output"] as? String ?? ""
                let isError = message["isError"] as? Bool ?? false
                items.append(ChatItem(
                    author: .assistant,
                    thinking: "",
                    tools: [ToolActivity(id: UUID().uuidString, name: "bash",
                                         argumentSummary: command, output: output,
                                         isError: isError, isRunning: false)],
                    timestamp: timestamp
                ))

            default:
                let text = text(of: blocks)
                guard !text.isEmpty else { continue }
                items.append(ChatItem(author: .notice, text: text, timestamp: timestamp))
            }
        }

        // Un mensaje del asistente puede venir partido: el modelo escribe, ejecuta herramientas,
        // y sigue. Se fusionan los consecutivos para no dibujar diez globos por un turno.
        return mergeConsecutiveAssistants(items)
    }

    private static func insertAssistant(_ item: ChatItem, into items: inout [ChatItem],
                                        toolLocation: inout [String: (itemIndex: Int, toolIndex: Int)]) {
        items.append(item)
        let itemIndex = items.count - 1
        for (toolIndex, tool) in items[itemIndex].tools.enumerated() {
            toolLocation[tool.id] = (itemIndex: itemIndex, toolIndex: toolIndex)
        }
    }

    private static func mergeConsecutiveAssistants(_ input: [ChatItem]) -> [ChatItem] {
        var output: [ChatItem] = []
        for item in input {
            guard var previous = output.last,
                  previous.author == .assistant, item.author == .assistant,
                  previous.tools.isEmpty || !item.tools.isEmpty || !item.text.isEmpty
            else {
                output.append(item)
                continue
            }
            if !item.text.isEmpty {
                previous.text = previous.text.isEmpty ? item.text : previous.text + "\n\n" + item.text
            }
            if !item.thinking.isEmpty { previous.thinking += item.thinking }
            previous.tools.append(contentsOf: item.tools)
            if item.errored {
                previous.errored = true
                previous.errorMessage = item.errorMessage
            }
            output[output.count - 1] = previous
        }
        return output
    }

    private static func text(of blocks: [[String: Any]]) -> String {
        blocks.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
    }

    private static func thinking(of blocks: [[String: Any]]) -> String {
        blocks.compactMap { block -> String? in
            block["type"] as? String == "thinking" ? block["thinking"] as? String : nil
        }.joined()
    }

    private static func summarize(arguments: Any?) -> String {
        guard let arguments = arguments as? [String: Any] else { return "" }
        for key in ["command", "path", "file_path", "pattern", "query", "url"] {
            if let value = arguments[key] as? String {
                return value.count > 120 ? String(value.prefix(120)) + "…" : value
            }
        }
        return arguments.keys.min() ?? ""
    }
}
