import AppKit
import P4WCore

/// Dibuja el ícono de la app con **el mismo pipeline que el gato**: la grilla de píxeles en texto.
///
/// Hay dos íconos, y el segundo es el que sorprende:
///
/// 1. El **estático**, para el `.dmg` y el Finder: el gato sobre un fondo redondeado oscuro, al estilo de
///    macOS (margen, esquinas redondeadas). Sale de `PixelGrid`, así que se verifica igual que el arte.
/// 2. El **del Dock, por estado**: cambia según lo que Pi está haciendo. No es un adorno — sirve cuando la
///    ventana está tapada por otra, que es justo cuando más querés saber si Pi terminó. Se actualiza
///    **solo cuando cambia el estado**, nunca por cuadro de animación: así no cuesta CPU.
enum IconRenderer {

    /// Los tamaños que pide un `.iconset` de macOS, con su nombre de archivo.
    static let iconsetEntries: [(name: String, size: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// El ícono completo, en PNG.
    ///
    /// - Parameters:
    ///   - size: el lado, en puntos.
    ///   - state: qué pose del gato se dibuja. El ícono estático usa el reposo.
    static func png(size: Int, state: CatState) -> Data? {
        let side = max(8, size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.setAllowsAntialiasing(true)

        // Fondo redondeado con margen, como los íconos de macOS. Sin margen en los tamaños chicos: a 16
        // puntos un margen se come el dibujo.
        let margin = CGFloat(side) * (side <= 32 ? 0.03 : 0.07)
        let rect = CGRect(x: margin, y: margin, width: CGFloat(side) - margin * 2,
                          height: CGFloat(side) - margin * 2)
        let radius = rect.width * 0.2237      // la proporción de las esquinas de macOS
        let background = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                                transform: nil)

        context.saveGState()
        context.addPath(background)
        context.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.24, green: 0.26, blue: 0.34, alpha: 1),
            CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: rect.maxY),
                                       end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        context.restoreGState()

        // El gato: la grilla de píxeles, escalada sin interpolación. Se dibuja a tamaño 16×16 en su propia
        // imagen y después se estira: así el píxel queda duro, que es lo que hace que se lea como píxel art.
        guard let gridImage = catImage(state: state) else { return nil }
        let catSide = CGFloat(side) * (side <= 32 ? 0.94 : 0.72)
        let catRect = CGRect(x: (CGFloat(side) - catSide) / 2, y: (CGFloat(side) - catSide) / 2
                             - CGFloat(side) * 0.01, width: catSide, height: catSide)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -CGFloat(side) * 0.012),
                          blur: CGFloat(side) * 0.03,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.draw(gridImage, in: catRect)
        context.restoreGState()

        // Un borde apenas más claro, que es lo que hace que el ícono no se pierda sobre un fondo oscuro.
        context.addPath(background)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        context.setLineWidth(max(1, CGFloat(side) * 0.006))
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// La grilla del gato como imagen de 16×16, para poder estirarla sin interpolación.
    private static func catImage(state: CatState) -> CGImage? {
        let frames = CatArt.frames(for: state)
        guard let frame = frames.first(where: { $0.isRestingPose }) ?? frames.first else { return nil }
        let grid = frame.grid
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: grid.columns, height: grid.height,
                                      bitsPerComponent: 8, bytesPerRow: grid.columns * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        for row in 0..<grid.height {
            for column in 0..<grid.columns {
                guard let color = grid.color(row: row, column: column) else { continue }
                // El contexto de CoreGraphics cuenta las filas desde abajo, la grilla desde arriba.
                let rect = CGRect(x: column, y: grid.height - row - 1, width: 1, height: 1)
                context.setFillColor(CGColor(red: CGFloat(color.red) / 255,
                                             green: CGFloat(color.green) / 255,
                                             blue: CGFloat(color.blue) / 255, alpha: 1))
                context.fill(rect)
            }
        }
        return context.makeImage()
    }

    /// Los diez PNG del `.iconset` y el `.icns` armado con `iconutil`.
    ///
    /// Devuelve lo que hizo, para que el comando que lo llama lo imprima: si algo falla, quiero el motivo.
    @discardableResult
    static func writeIconSet(into root: String, state: CatState = .enReposo) -> [String] {
        var log: [String] = []
        let iconset = "\(root)/icon.iconset"
        try? FileManager.default.removeItem(atPath: iconset)
        do {
            try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        } catch {
            return ["no se pudo crear \(iconset): \(error)"]
        }
        for entry in iconsetEntries {
            guard let data = png(size: entry.size, state: state) else {
                log.append("\(entry.name): no se pudo dibujar")
                continue
            }
            let path = "\(iconset)/\(entry.name).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                log.append("\(entry.name): no se pudo escribir (\(error))")
            }
        }
        log.append("\(iconsetEntries.count) PNG en \(iconset)")

        // El .icns lo arma `iconutil`, que es la herramienta de macOS: no hay motivo para escribir un
        // formato de contenedor a mano.
        let icns = "\(root)/P4W.icns"
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        run.arguments = ["-c", "icns", iconset, "-o", icns]
        do {
            try run.run()
            run.waitUntilExit()
            log.append(run.terminationStatus == 0
                       ? "✓ \(icns)"
                       : "iconutil falló con estado \(run.terminationStatus)")
        } catch {
            log.append("no se pudo ejecutar iconutil: \(error)")
        }
        return log
    }

    /// Los cuadros del gato en una tira horizontal, para poder verlos de un vistazo.
    ///
    /// Se usa en la documentación: sin permiso de Grabación de Pantalla no se pueden tomar capturas de la
    /// app, pero el arte sí se puede volcar — **y es el mismo código que dibuja el gato en la ventana**.
    static func frameStrip(scale: Int = 6, spacing: Int = 4) -> Data? {
        let grids = CatArt.allGrids.map { $0.grid }
        guard let first = grids.first else { return nil }
        let side = first.columns * scale
        let gap = spacing
        let width = grids.count * side + (grids.count - 1) * gap
        let height = side
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        for (index, grid) in grids.enumerated() {
            guard let image = rasterized(grid) else { continue }
            let rect = CGRect(x: CGFloat(index * (side + gap)), y: 0,
                              width: CGFloat(side), height: CGFloat(side))
            context.draw(image, in: rect)
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Una grilla cualquiera dibujada a su tamaño real de píxeles.
    static func rasterized(_ grid: PixelGrid) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: grid.columns, height: grid.height,
                                      bitsPerComponent: 8, bytesPerRow: grid.columns * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        for row in 0..<grid.height {
            for column in 0..<grid.columns {
                guard let color = grid.color(row: row, column: column) else { continue }
                let rect = CGRect(x: column, y: grid.height - row - 1, width: 1, height: 1)
                context.setFillColor(CGColor(red: CGFloat(color.red) / 255,
                                             green: CGFloat(color.green) / 255,
                                             blue: CGFloat(color.blue) / 255, alpha: 1))
                context.fill(rect)
            }
        }
        return context.makeImage()
    }

    /// Lo que la documentación necesita, en `docs/img/`.
    ///
    /// Se genera desde el mismo código que dibuja la app: si el gato cambia, la documentación se rehace con
    /// un comando y no puede quedar mostrando algo que ya no existe.
    @discardableResult
    static func writeDocumentationImages(into root: String = "docs/img") -> [String] {
        var log: [String] = []
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            return ["no se pudo crear \(root): \(error)"]
        }
        let files: [(String, Data?)] = [
            ("icono-256.png", png(size: 256, state: .enReposo)),
            ("icono-512.png", png(size: 512, state: .enReposo)),
            ("gato-cuadros.png", frameStrip()),
        ]
        for (name, data) in files {
            guard let data else { log.append("\(name): no se pudo dibujar"); continue }
            do {
                try data.write(to: URL(fileURLWithPath: "\(root)/\(name)"))
                log.append("\(name): \(data.count) bytes")
            } catch {
                log.append("\(name): no se pudo escribir (\(error))")
            }
        }
        return log
    }

    /// El ícono del Dock para un estado, ya listo para `NSApp.applicationIconImage`.
    static func dockImage(for state: CatState) -> NSImage? {
        guard let data = png(size: 256, state: state) else { return nil }
        return NSImage(data: data)
    }
}
