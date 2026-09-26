import Foundation

/// El gato: los cuadros y sus tiempos.
///
/// El arte está **acá, en texto**, y no en un PNG. Ver `PixelGrid` para el porqué: se revisa en el diff,
/// no hay binarios en el repo, no hay licencias de por medio, y sobre todo **se puede verificar**.
///
/// Los tiempos son **por cuadro**, no un FPS fijo. Las guías de sprite art coinciden en que el tiempo es
/// lo que hace que una animación se vea bien: anticipación lenta, acción rápida, recuperación lenta.
public enum CatArt {

    /// El lado del cuadro, en píxeles. Está acá porque **el tamaño en pantalla tiene que ser múltiplo de
    /// esto**: ver `CatSize`.
    public static let gridSide: Int = 16

    /// La paleta. Cerrada: cualquier carácter fuera de esta lista es un error, y `PixelGrid.problems()`
    /// lo reporta.
    public static let palette: [Character: RGB] = [
        "#": RGB(28, 26, 34),      // contorno
        "W": RGB(252, 252, 255),   // pelaje
        "S": RGB(214, 216, 226),   // sombra del pelaje
        "P": RGB(240, 160, 175),   // rosa (orejas, nariz)
        "E": RGB(40, 38, 48),      // ojos
    ]

    /// Pose base: gato blanco sentado, con las orejas y las patas delanteras.
    ///
    /// Todavía **no tiene cola**: a 16 columnas, la cola necesita que el cuerpo sea más angosto y eso es
    /// una decisión de arte, no un detalle. Se decide mirando el PNG.
    static let base: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    /// El mismo gato con los ojos cerrados: un parpadeo. Es el segundo cuadro del reposo, y alcanza para
    /// que la animación se vea viva sin gastar nada.
    static let blink: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#S#WWWWWWWW#W#.",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    // ── Variaciones por estado ───────────────────────────────────────────────
    //
    // Todas son **ediciones mínimas de la pose base**: la silueta no se toca, solo cambian ojos, orejas y
    // patas. No es una limitación, es lo correcto en animación — si la silueta cambia entre cuadros, el
    // personaje "salta". Y además así la pose que ya está aprobada queda intacta.

    /// Pensando: los ojos miran **arriba** (una sola fila en vez de dos), que es lo que hace que se lea
    /// como "está pensando" y no como "está mirando".
    static let thinking: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEWWWWWWWWEW#.",
        ".#S#WWWWWWWW#W#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    /// Pensando, segundo cuadro: **la oreja derecha se levanta** un píxel. Es la variación más chica
    /// posible y alcanza para que se vea vivo sin distraer.
    static let thinkingEar: [String] = [
        "................",
        "...#.........#..",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEWWWWWWWWEW#.",
        ".#S#WWWWWWWW#W#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    /// Escribiendo: la pata **izquierda se mueve** un píxel. Las dos patas se ven al final del cuerpo, y
    /// mover una sola alcanza para leer "está tecleando".
    static let writingPaw: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".###WWW##WWWW##.",
    ]

    /// Trabajando: las dos patas levantadas, como cuando las apoya sobre algo. Se distinguen de
    /// "escribiendo" porque ahí se mueve una sola.
    static let workingPaws: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SEWWWWWWWWEW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
        "..#WWW#..#WWW#..",
    ]

    /// Te espera: **ojos más grandes** (de dos píxeles de ancho) y la cola levantada. Es el estado que pide
    /// algo, así que es el que más se tiene que notar.
    static let waiting: [String] = [
        "................",
        "...#........#...",
        "..#P#......#P#..",
        "..#PP#....#PP#..",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SEEWWWWWWEEW#.",
        ".#SEEWWWWWWEEW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    /// Problema: **orejas caídas** y ojos entornados. Las orejas son lo primero que se mira, así que con
    /// eso alcanza para que se entienda sin leer la etiqueta.
    static let trouble: [String] = [
        "................",
        "................",
        "..#PP#....#PP#..",
        ".#SPPP#..#PPPS#.",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".#S#WWWWWWWW#W#.",
        ".#SEWWWWWWWWEW#.",
        ".#SWWWWPPWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        "..#WWWWWWWWWW#..",
        ".#WWWWWWWWWWWW##",
        ".#WWWWWWWWWWWW##",
        ".#SWWWWWWWWWWW#.",
        ".#SWWWWWWWWWWW#.",
        ".##WWWW##WWWW##.",
    ]

    /// Dormido: los ojos cerrados. Es el mismo cuadro del parpadeo, pero acá es el estado, no un instante.
    static var asleep: [String] { blink }

    /// Un cuadro con su duración. La duración va con el cuadro: la animación no corre a FPS fijo.
    public struct Frame: Sendable {
        public let grid: PixelGrid
        public let seconds: Double
        /// Con "Reducir movimiento" activo se muestra solo este cuadro de la secuencia.
        public let isRestingPose: Bool
        public init(grid: PixelGrid, seconds: Double, isRestingPose: Bool = false) {
            self.grid = grid
            self.seconds = seconds
            self.isRestingPose = isRestingPose
        }
    }

    /// El reposo: ojos abiertos un rato largo, parpadeo corto. Dos cuadros alcanzan — y el parpadeo es
    /// rápido porque un parpadeo lento se ve mal.
    public static let idle: [Frame] = [
        Frame(grid: PixelGrid(rows: base, palette: palette), seconds: 2.6, isRestingPose: true),
        Frame(grid: PixelGrid(rows: blink, palette: palette), seconds: 0.12),
    ]

    /// Cuadros por estado. Todos los estados tienen los suyos: no queda ninguno usando el reposo por
    /// falta de dibujo, y hay una verificación que lo exige.
    public static func frames(for state: CatState) -> [Frame] {
        func frame(_ rows: [String], _ seconds: Double, resting: Bool = false) -> Frame {
            Frame(grid: PixelGrid(rows: rows, palette: palette), seconds: seconds,
                  isRestingPose: resting)
        }
        switch state {
        case .dormido:
            // Duerme: ojos cerrados, sin parpadeo que mostrar. Un solo cuadro, y es la pose de reposo.
            return [frame(asleep, 1.0, resting: true)]
        case .enReposo:
            return idle
        case .pensando:
            // La oreja se levanta cada tanto: irregular a propósito, un tic parejo se ve mecánico.
            return [frame(thinking, 0.9, resting: true), frame(thinkingEar, 0.25),
                    frame(thinking, 1.4), frame(thinkingEar, 0.2)]
        case .escribiendo:
            // Tecleo: rápido y parejo, como los dedos.
            return [frame(base, 0.14, resting: true), frame(writingPaw, 0.14)]
        case .trabajando:
            // Ocupado de verdad: las patas suben y bajan, más lento que teclear.
            return [frame(workingPaws, 0.5, resting: true), frame(base, 0.35)]
        case .esperandote:
            // Inquieto: alterna entre la pose que pide y volver a mirar, para no quedarse congelado.
            return [frame(waiting, 1.1, resting: true), frame(base, 0.5)]
        case .problema:
            return [frame(trouble, 1.6, resting: true), frame(asleep, 0.3)]
        }
    }

    /// Todas las grillas, para poder verificarlas de una sola pasada.
    public static var allGrids: [(name: String, grid: PixelGrid)] {
        [("base", PixelGrid(rows: base, palette: palette)),
         ("blink", PixelGrid(rows: blink, palette: palette)),
         ("pensando", PixelGrid(rows: thinking, palette: palette)),
         ("pensando-oreja", PixelGrid(rows: thinkingEar, palette: palette)),
         ("escribiendo", PixelGrid(rows: writingPaw, palette: palette)),
         ("trabajando", PixelGrid(rows: workingPaws, palette: palette)),
         ("te-espera", PixelGrid(rows: waiting, palette: palette)),
         ("problema", PixelGrid(rows: trouble, palette: palette))]
    }
}
