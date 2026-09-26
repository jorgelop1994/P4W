import Foundation

/// Acumulador de registros JSONL con framing estricto.
///
/// El protocolo RPC de Pi se parte **solo** en LF (`\n`). No usar `readline` ni un splitter
/// genérico de líneas Unicode: `U+2028` y `U+2029` son válidos dentro de strings JSON y
/// romperían el parseo de forma silenciosa. Se acepta CRLF descartando un `\r` previo.
public struct JSONLAccumulator {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var records: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var record = buffer[buffer.startIndex..<index]
            if record.last == 0x0D { record = record.dropLast() }
            if !record.isEmpty { records.append(Data(record)) }
            buffer = buffer[buffer.index(after: index)...]
        }
        return records
    }

    /// Bytes que no formaron un registro completo. Útil para diagnóstico.
    public var pendingBytes: Int { buffer.count }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

/// Registro RPC ya decodificado, sin imponer un modelo tipado todavía.
public enum RPCRecord {
    case response(id: String?, command: String?, success: Bool, data: [String: Any]?, error: String?)
    case event(type: String, payload: [String: Any])
    case unparseable(String)

    public static func decode(_ data: Data) -> RPCRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unparseable(String(decoding: data, as: UTF8.self))
        }
        let type = object["type"] as? String ?? ""

        if type == "response" {
            return .response(
                id: object["id"] as? String,
                command: object["command"] as? String,
                success: object["success"] as? Bool ?? false,
                data: object["data"] as? [String: Any],
                error: object["error"] as? String
            )
        }
        return .event(type: type, payload: object)
    }
}

/// Codificación de comandos salientes. Una línea JSON + LF, sin excepciones.
public enum RPCCommand {

    public static func encode(id: String?, type: String, fields: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = fields
        object["type"] = type
        if let id { object["id"] = id }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// `prompt` con soporte de imágenes base64, tal como lo define el protocolo.
    public static func prompt(
        id: String,
        message: String,
        images: [[String: Any]] = [],
        streamingBehavior: String? = nil
    ) throws -> Data {
        var fields: [String: Any] = ["message": message]
        if !images.isEmpty { fields["images"] = images }
        if let streamingBehavior { fields["streamingBehavior"] = streamingBehavior }
        return try encode(id: id, type: "prompt", fields: fields)
    }
}
