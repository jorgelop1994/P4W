import Foundation

/// Texto que viene de una terminal, limpiado para mostrarlo en una interfaz gráfica.
///
/// Las extensiones de Pi escriben su estado con el tema de la TUI: por ejemplo
/// `ctx.ui.theme.fg("dim", "Cache 97.3%")`, que devuelve el texto envuelto en **códigos ANSI**. En una
/// terminal eso es color; en P4W sería basura visible. Se quitan las secuencias de control y se conserva
/// el texto, que es donde está el dato.
public enum TerminalText {

    /// Quita secuencias de escape ANSI (CSI, OSC y los códigos simples) y normaliza espacios.
    public static func clean(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character == "\u{1B}" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                let marker = text[next]

                if marker == "[" {
                    // CSI: ESC [ … termina en una letra (0x40–0x7E).
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex, let scalar = text[cursor].unicodeScalars.first {
                        if scalar.value >= 0x40, scalar.value <= 0x7E {
                            cursor = text.index(after: cursor)
                            break
                        }
                        cursor = text.index(after: cursor)
                    }
                    index = cursor
                    continue
                }
                if marker == "]" {
                    // OSC: ESC ] … termina en BEL o ESC \
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let current = text[cursor]
                        if current == "\u{7}" {
                            cursor = text.index(after: cursor)
                            break
                        }
                        if current == "\u{1B}" {
                            let after = text.index(after: cursor)
                            if after < text.endIndex, text[after] == "\\" {
                                cursor = text.index(after: after)
                                break
                            }
                        }
                        cursor = text.index(after: cursor)
                    }
                    index = cursor
                    continue
                }
                // Otros escapes de dos caracteres (ESC 7, ESC =, etc.).
                index = text.index(after: next)
                continue
            }

            // Caracteres de control que no aportan nada en una interfaz gráfica.
            if character == "\u{7}" || character == "\r" {
                index = text.index(after: index)
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
