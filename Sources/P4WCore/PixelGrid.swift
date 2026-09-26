import AppKit
import Foundation

/// Un color de la paleta. Se guarda como bytes y no como `NSColor` porque la grilla es dato, no interfaz.
public struct RGB: Sendable, Equatable {
    public let red: UInt8, green: UInt8, blue: UInt8
    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }
    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// Un cuadro de píxel art, escrito como texto: una fila por línea y un carácter por píxel.
///
/// Está en texto y no en PNG a propósito: así se revisa en el diff, no hay binarios en el repo, no hay
/// dudas de licencia, y **se puede verificar** — que las filas midan lo mismo, que la paleta sea cerrada
/// (ningún carácter fuera de la lista). El carácter `.` es transparente y no va en la paleta.
public struct PixelGrid: Sendable, Equatable {
    public let rows: [String]
    public let palette: [Character: RGB]

    public static let transparent: Character = "."

    public init(rows: [String], palette: [Character: RGB]) {
        self.rows = rows
        self.palette = palette
    }

    public var columns: Int { rows.first?.count ?? 0 }
    public var height: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty || columns == 0 }

    /// Lo que está mal en la grilla. Se devuelve en vez de fallar: un cuadro con un problema tiene que
    /// poder mirarse igual (y el problema, reportarse).
    public func problems() -> [String] {
        var found: [String] = []
        if rows.isEmpty { found.append("la grilla no tiene filas") }
        let width = columns
        for (index, row) in rows.enumerated() where row.count != width {
            found.append("la fila \(index) mide \(row.count) y la primera mide \(width)")
        }
        // La paleta tiene que ser cerrada: un carácter de más es un color que nadie definió.
        var unknown: Set<Character> = []
        for row in rows {
            for character in row where character != Self.transparent && palette[character] == nil {
                unknown.insert(character)
            }
        }
        if !unknown.isEmpty {
            let list = unknown.sorted().map { String($0) }.joined(separator: ", ")
            found.append("hay caracteres fuera de la paleta: \(list)")
        }
        return found
    }

    public func hasProblem() -> Bool { !problems().isEmpty }

    /// Colores de la paleta que ningún píxel usa. No es un error, pero conviene saberlo: un color
    /// declarado y no usado es una promesa vacía, o una sombra que se olvidó de pintar.
    public func unusedColors() -> [Character] {
        let used = Set(usage().keys)
        return palette.keys.filter { !used.contains($0) }.sorted()
    }

    /// El color de una celda. `nil` = transparente.
    public func color(row: Int, column: Int) -> RGB? {
        guard row >= 0, row < rows.count else { return nil }
        let characters = Array(rows[row])
        guard column >= 0, column < characters.count else { return nil }
        let character = characters[column]
        guard character != Self.transparent else { return nil }
        return palette[character]
    }

    /// Cuántos píxeles pinta de cada color, para poder reportar el uso de la paleta.
    public func usage() -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for row in rows {
            for character in row where character != Self.transparent {
                counts[character, default: 0] += 1
            }
        }
        return counts
    }

    /// Vuelca el cuadro a PNG, escalado por bloques (vecino más cercano por construcción: cada píxel se
    /// pinta como un cuadrado de `scale` × `scale`, así que no hay interpolación que pueda emborronar).
    public func pngData(scale: Int = 1) -> Data? {
        let factor = max(1, scale)
        let width = columns * factor
        let height = rows.count * factor
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        // Los bytes se escriben **directo**, sin pasar por `NSColor`. Con `setColor` sobre un bitmap
        // `deviceRGB`, AppKit emite cientos de avisos de espacio de color por cada píxel, y además hay que
        // convertir cada color. Escribir RGBA a mano evita las dos cosas.
        //
        // El alfa acá solo toma 0 o 255, así que da igual si el formato espera alfa premultiplicado:
        // ambos valores son puntos fijos de la premultiplicación.
        for row in 0..<rows.count {
            for column in 0..<columns {
                guard let color = color(row: row, column: column) else { continue }
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let x = column * factor + dx
                        let y = row * factor + dy
                        let offset = y * width * 4 + x * 4
                        pixels[offset] = color.red
                        pixels[offset + 1] = color.green
                        pixels[offset + 2] = color.blue
                        pixels[offset + 3] = 255
                    }
                }
            }
        }

        // El PNG se crea **etiquetado como sRGB**, no a través de un `NSBitmapImageRep` con
        // `colorSpaceName: .deviceRGB`. La diferencia no es teórica: con `deviceRGB`, al leer el archivo
        // los colores volvían convertidos — se escribía #1C1A22 y se leía #25232D, porque los bytes se
        // interpretaban como RGB del dispositivo. Con el espacio explícito el ida y vuelta es exacto, y
        // el ida y vuelta exacto es lo que permite verificar el arte sin poder verlo.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Lee un PNG de vuelta y devuelve el color de cada celda, en las mismas coordenadas que la grilla.
    ///
    /// Existe por un motivo: **yo no puedo ver la imagen**. Si el volcado invierte las filas o desalinea
    /// los bloques, sin esto no me enteraría. Así el autodiagnóstico puede comparar el PNG contra la
    /// grilla y decirlo.
    public static func readBack(png: Data, scale: Int = 1, columns: Int, rows: Int) -> [[RGB?]]? {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        let factor = max(1, scale)
        var result: [[RGB?]] = []
        for row in 0..<rows {
            var line: [RGB?] = []
            for column in 0..<columns {
                // Se mira el centro del bloque: así el borde no confunde la lectura.
                let x = column * factor + factor / 2
                let y = row * factor + factor / 2
                guard x < rep.pixelsWide, y < rep.pixelsHigh,
                      let color = rep.colorAt(x: x, y: y) else { line.append(nil); continue }
                let alpha = Int((color.alphaComponent * 255).rounded())
                guard alpha > 128 else { line.append(nil); continue }
                // Los componentes se leen **directo**, sin `usingColorSpace`. Convertir el color a sRGB
                // era el error: `colorAt` devuelve el color en el espacio del bitmap, y convertir desde
                // ahí mueve los valores (se escribía #1C1A22 y se leía #25232D). El PNG ya se etiqueta
                // como sRGB al escribirlo, así que no hay nada que convertir.
                line.append(RGB(
                    UInt8((color.redComponent * 255).rounded()),
                    UInt8((color.greenComponent * 255).rounded()),
                    UInt8((color.blueComponent * 255).rounded())
                ))
            }
            result.append(line)
        }
        return result
    }
}
