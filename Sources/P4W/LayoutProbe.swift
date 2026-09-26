import P4WCore
import SwiftUI

/// Mide el layout de la app desde adentro y lo imprime.
///
/// Existe por un problema concreto de este proyecto: **la pantalla no se puede ver** (no hay permiso de
/// Grabación de Pantalla), así que "quedó más grande" o "la barra arranca pegada" no se pueden dar por
/// hechos mirando. Medir es la única forma de verificarlo, y hay una trampa conocida: SwiftUI puede
/// **cachear el layout del label de un `Menu`**, con lo que el dibujo se actualiza y el tamaño no. Ese bug
/// es invisible desde afuera; medido, canta.
///
/// Se usa con `P4W --measure-layout`, que imprime y sale. Fuera de ese modo no hace absolutamente nada.
enum LayoutProbe {
    nonisolated(unsafe) static var enabled = false

    private static let lock = NSLock()
    private static var sizes: [String: String] = [:]

    /// Adjunto para poner en un `.background(...)`: reporta tamaño y posición del punto de anclaje.
    static func attachment(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear
                .task(id: proxy.size) {
                    guard enabled else { return }
                    report(name, size: proxy.size, origin: proxy.frame(in: .global).origin)
                }
        }
    }

    private static var rows: Set<String> = []
    private static var historyBuilt = false
    private static var historySeen = false

    /// Si la sección del historial se **armó** en la vista. Plegada no se arma: el `ForEach` de 400 y pico
    /// conversaciones no se crea siquiera, así que ninguna fila puede construirse.
    ///
    /// Se mide esto y no "cuántas filas del historial se construyeron" por una razón que apareció midiendo:
    /// el historial queda **debajo del área visible** de la columna, y una pila perezosa no construye lo que
    /// está fuera. Medir filas daba 0 en los dos casos —con la sección plegada y sin plegar—, o sea que no
    /// medía nada. Lo que sí se puede medir es si la sección se arma o no.
    static func noteHistory(built: Bool) {
        guard enabled else { return }
        lock.lock(); historySeen = true; historyBuilt = built; lock.unlock()
    }

    /// Cuenta una fila de conversación que **se construyó de verdad**.
    ///
    /// Es la medición de que plegar el historial sirve para algo: plegado, la columna no tiene que construir
    /// esas filas. No alcanza con que "no se vean" — se mide cuántas se construyeron.
    static func noteRow(_ id: String) {
        guard enabled else { return }
        lock.lock(); rows.insert(id); lock.unlock()
    }

    static func report(_ name: String, size: CGSize, origin: CGPoint) {
        let text = String(format: "%.0f×%.0f en (%.0f, %.0f)",
                          size.width, size.height, origin.x, origin.y)
        lock.lock()
        let previous = sizes[name]
        sizes[name] = text
        lock.unlock()
        // Solo se imprime cuando cambia: así el ruido no tapa el dato que importa.
        if previous != text {
            print("  \(name): \(text)")
        }
    }

    static func finish(avatarSize: CatSize? = nil) {
        lock.lock()
        let all = sizes
        let rowCount = rows.count
        lock.unlock()
        print("\n--- medidas ---")
        // El estado leído del disco, para poder contrastarlo con lo que se midió.
        if let store = try? SpacesStore() {
            print("  secciones plegadas (de spaces.json): "
                  + (store.collapsedKeys().isEmpty ? "(ninguna)"
                     : store.collapsedKeys().sorted().joined(separator: " · ")))
        }
        if let avatarSize {
            print("  tamaño elegido: \(avatarSize.label) → cada píxel mide \(avatarSize.pixelPoints) puntos")
        }
        for name in all.keys.sorted() { print("  \(name): \(all[name] ?? "?")") }
        print("  filas de conversación construidas: \(rowCount)")
        print("  sección del historial: "
              + (historySeen ? (historyBuilt ? "armada" : "**no armada** (plegada)")
                             : "no se llegó a evaluar"))
        print("--- fin ---")
    }
}
