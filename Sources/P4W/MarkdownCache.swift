import Foundation
import SwiftUI

/// Caché de markdown: parsear y convertir **fuera** de `body`.
///
/// Motivo, y es la causa del cuelgue al hacer scroll: el cuerpo de una vista se reevalúa muchas veces
/// por segundo mientras se desplaza, y ahí adentro yo hacía dos trabajos caros **en cada render**:
/// parsear el markdown en bloques y convertir cada bloque a `AttributedString`. Con 80 mensajes
/// visibles eso es trabajo multiplicado por cada cuadro.
///
/// La recomendación de la investigación es explícita: *convertir una vez y cachear fuera de `body`,
/// guardar la representación que se presenta, y rehacerla solo si cambia la entrada*. Es lo que hace
/// esto, con un tope de entradas para no crecer sin límite.
enum MarkdownCache {

    private static let lock = NSLock()
    private static var blocks: [String: [MarkdownBlock]] = [:]
    private static var inline: [String: AttributedString] = [:]
    /// Orden de llegada, para descartar lo más viejo cuando se pasa del tope.
    private static var order: [String] = []
    /// El tope es por **caracteres guardados**, no por cantidad de entradas: 500 mensajes cortos no
    /// son nada, pero 500 mensajes de 15.000 caracteres son 15 MB de texto más sus representaciones.
    /// 4 MB alcanza para todo lo visible y mantiene el consumo acotado.
    private static let characterLimit = 4 * 1_048_576
    private static var charactersHeld = 0

    private static var hits = 0
    private static var misses = 0

    static func parsedBlocks(_ text: String) -> [MarkdownBlock] {
        lock.lock()
        if let cached = blocks[text] {
            hits += 1
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = MarkdownParser.parse(text)

        lock.lock()
        misses += 1
        blocks[text] = parsed
        order.append(text)
        charactersHeld += text.count
        trimIfNeeded()
        lock.unlock()
        return parsed
    }

    static func inlineText(_ text: String) -> AttributedString {
        lock.lock()
        if let cached = inline[text] {
            hits += 1
            lock.unlock()
            return cached
        }
        lock.unlock()

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = true
        let value = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        lock.lock()
        misses += 1
        inline[text] = value
        order.append(text)
        charactersHeld += text.count
        trimIfNeeded()
        lock.unlock()
        return value
    }

    /// Se llama con el lock tomado. Se descarta lo más viejo hasta quedar por debajo del tope.
    private static func trimIfNeeded() {
        while charactersHeld > characterLimit, !order.isEmpty {
            let key = order.removeFirst()
            charactersHeld -= key.count
            blocks.removeValue(forKey: key)
            inline.removeValue(forKey: key)
        }
    }

    static func statistics() -> (hits: Int, misses: Int, blocks: Int, inline: Int, characters: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, misses, blocks.count, inline.count, charactersHeld)
    }

    static func reset() {
        lock.lock()
        charactersHeld = 0
        blocks.removeAll()
        inline.removeAll()
        order.removeAll()
        hits = 0
        misses = 0
        lock.unlock()
    }
}
