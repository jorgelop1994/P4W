import P4WCore
import SwiftUI

/// El gato: el cuadro del estado actual, con su etiqueta al lado.
///
/// La etiqueta no es decoración. **El gato nunca es la única señal**: con "Reducir movimiento" se queda
/// quieto, y una persona que use lector de pantalla no tiene gato que leer. El estado va escrito.
///
/// Y el consumo está cuidado a propósito: cuando no hay que animar (movimiento reducido, ventana tapada,
/// app inactiva, o un estado de un solo cuadro) **no se enciende ningún temporizador** — no se anima
/// despacio, no se anima.
struct CatAvatarView: View {
    let state: CatState
    var style: Style = .full

    /// Cuánto ocupa y qué muestra. Cada estilo responde a un lugar distinto: la canaleta tiene 30 puntos y
    /// el compositor tiene al lado el campo de texto.
    enum Style {
        /// Gato y etiqueta completa. Es el de la zona de estado.
        case full
        /// Solo el gato. Para la canaleta del mensaje: al lado está el mensaje.
        case catOnly
        /// Gato y etiqueta corta. Para el compositor: al lado está el campo de texto.
        case catWithShortLabel
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowVisibility: WindowVisibilityObserver
    @State private var index = 0
    @State private var hovering = false
    /// Congelado mientras lo estás usando, y unos segundos después de que el mouse se va.
    ///
    /// Es lo que hace que el menú **no se cierre bajo la mano**: al ir del gato al menú el mouse sale del
    /// gato, y si la animación retomara en ese instante volvería a redibujar la vista que ancla el menú. Se
    /// esperan unos segundos en vez de reanudar de inmediato: lo que tarda una persona en elegir una opción
    /// no tiene nada que ver con lo que tarda un cuadro de la animación.
    @State private var frozen = false
    @State private var thawTask: Task<Void, Never>?

    /// El lado del gato. Sale del tamaño elegido, que es múltiplo del cuadro: ver `CatSize`.
    private var side: CGFloat { model.avatarSize.points }

    /// Si la vista se estira para llenar el ancho disponible. Solo la ubicación en la zona de estado lo
    /// hace; las demás tienen que ocupar lo suyo y nada más.
    private var stretches: Bool { style == .full }

    private var cat: some View {
        // Un `Menu` y no un `.contextMenu`: un menú contextual **no se descubre**, y el gato no parece un
        // botón. Así alcanza con el clic normal, que es lo primero que uno intenta. El clic derecho sigue
        // funcionando porque es el mismo menú.
        Menu {
            positionOptions
        } label: {
            PixelFrameView(grid: shown.grid)
                .opacity(state == .dormido ? 0.55 : 1)
                .overlay(
                    // Resaltado al pasar el mouse: es la señal de que se puede hacer algo.
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(hovering ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                // El `.id` con el tamaño **fuerza una vista nueva** cuando cambia: sin esto, SwiftUI
                // reutiliza el label del menú y el tamaño elegido no se veía, aunque el dibujo sí se
                // actualizara (por eso la animación andaba y el tamaño no).
                .id("gato-\(Int(side))")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // El tamaño se aplica **afuera** del menú. Adentro, SwiftUI cachea el layout del label; afuera, el
        // cambio de tamaño es un cambio de layout del padre y no hay caché que valga.
        .frame(width: side, height: side)
        .fixedSize()
        // El probe va **afuera** del menú: adentro el label no recibe layout (mide 0×0), que es justamente
        // la razón de que el tamaño no se pudiera cambiar desde adentro.
        .background(LayoutProbe.attachment("gato"))
        .onHover { inside in
            hovering = inside
            thawTask?.cancel()
            if inside {
                frozen = true
            } else {
                thawTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { return }
                    frozen = false
                }
            }
        }
        .accessibilityLabel("Pi está \(state.label). Clic para cambiar al gato de lugar.")
    }

    private var label: some View {
        Text(style == .catWithShortLabel ? state.shortLabel : state.label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Ancho fijo en el compositor: si el ancho cambiara con cada estado, la barra de escritura se
            // correría sola cada vez que Pi pasa de pensar a escribir. Una barra que se mueve es peor que
            // una etiqueta un poco más ancha.
            .frame(width: style == .catWithShortLabel ? 62 : nil, alignment: .leading)
    }

    private var frames: [CatArt.Frame] { CatArt.frames(for: state) }

    private var isRunning: Bool {
        guard !frozen else { return false }
        return CatAnimation.isRunning(state: state, frames: frames, reduceMotion: reduceMotion,
                                      windowVisible: windowVisibility.isVisible,
                                      appActive: windowVisibility.isActive)
    }

    /// Qué cuadro se muestra. Parado, siempre la pose de reposo: el gato no desaparece por no animarse.
    private var shown: CatArt.Frame {
        guard !frames.isEmpty else {
            return CatArt.Frame(grid: PixelGrid(rows: [], palette: CatArt.palette), seconds: 1)
        }
        let wanted = isRunning ? index % frames.count : CatAnimation.restingIndex(frames)
        return frames[min(wanted, frames.count - 1)]
    }

    private var position: AvatarPosition { model.avatarPosition }

    var body: some View {
        if style == .catOnly { compactBody } else { labelledBody }
    }

    private var compactBody: some View {
        cat
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pi está \(state.label). Clic para cambiar al gato de lugar.")
            .help(helpText)
            .task(id: taskKey) { await animate() }
    }

    private var labelledBody: some View {
        HStack(spacing: 6) {
            // El orden se invierte según la ubicación: el gato mira hacia el centro de la ventana, y la
            // etiqueta queda del lado que no tapa el texto.
            if stretches, position.labelFirst { Spacer(minLength: 0) }
            if position.labelFirst {
                label
                cat
            } else {
                cat
                label
            }
            // El relleno flexible **solo** en el estilo completo, que es el único que se empuja contra un
            // borde. Con el relleno puesto, en el compositor el gato se comía todo el espacio de la fila y
            // empujaba la barra de escritura hacia la derecha.
            if stretches, !position.labelFirst { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pi está \(state.label). Clic para cambiar al gato de lugar.")
        .help(helpText)
        .task(id: taskKey) { await animate() }
    }

    private var taskKey: String { "\(state.rawValue)-\(isRunning)" }

    /// El globo del gato: dice el estado y, sin vueltas, qué se puede hacer con él. Un estado que no dice
    /// cómo se cambia de lugar deja la interacción escondida.
    private var helpText: String {
        "Pi está \(state.label). Clic para cambiar al gato de lugar."
    }

    /// Los tiempos son por cuadro, así que se duerme lo que dura el cuadro actual en vez de usar un FPS
    /// fijo. `sleep` y no un temporizador que consulta el reloj: mientras duerme, no trabaja.
    private func animate() async {
        guard isRunning else {
            if index != 0 { index = CatAnimation.restingIndex(frames) }
            return
        }
        while !Task.isCancelled {
            let wait = frames[min(index, frames.count - 1)].seconds
            try? await Task.sleep(nanoseconds: UInt64(max(0.02, wait) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            index = (index + 1) % frames.count
        }
    }

    @ViewBuilder
    private var positionOptions: some View {
        Section("Ubicación") {
            ForEach(AvatarPosition.allCases) { option in
                Button {
                    model.avatarPosition = option
                } label: {
                    Text(option == position ? "✓ \(option.label)" : option.label)
                }
            }
        }
        Divider()
        // El tamaño se elige acá y no en configuración: es la misma decisión, mirándolo.
        //
        // **Sin submenú**, y no es preferencia de estilo: un submenú anidado se cierra solo cuando la vista
        // que lo ancla se vuelve a dibujar, y el gato se redibuja en cada cuadro de la animación (cada
        // 0,14 s cuando está escribiendo). Las opciones aparecían una fracción de segundo y se iban. Un
        // menú plano no tiene ese problema.
        Section("Tamaño") {
            ForEach(CatSize.allCases) { size in
                Button {
                    model.avatarSize = size
                } label: {
                    Text(size == model.avatarSize ? "✓ \(size.label)" : size.label)
                }
            }
        }
        Divider()
        Button {
            model.dockIconLive.toggle()
        } label: {
            Text(model.dockIconLive ? "✓ Gato en el Dock" : "Gato en el Dock")
        }
        Divider()
        Text("El gato muestra qué está haciendo Pi")
    }
}

/// La explicación de que el gato se puede mover de lugar.
///
/// Aparece **una sola vez**: mientras la persona no haya elegido una ubicación y no la haya descartado. Un
/// gato que se puede arrastrar pero no lo dice es una función que existe solo para quien la escribió.
struct AvatarHint: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.system(size: 9))
            Text("El gato muestra qué está haciendo Pi. Clic en él para moverlo de lugar.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                model.dismissAvatarHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("No volver a mostrar esta explicación")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }
}

/// El estado escrito, sin el gato.
///
/// Existe para la posición de la canaleta: ahí la etiqueta no entra al lado del gato, así que se escribe
/// acá. La regla no se negocia — **el gato nunca es la única señal**.
struct CatStateLine: View {
    let state: CatState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(state.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .accessibilityLabel("Pi está \(state.label)")
    }

    private var symbol: String {
        switch state {
        case .dormido: return "moon.zzz"
        case .enReposo: return "pause.circle"
        case .pensando: return "ellipsis.bubble"
        case .escribiendo: return "text.cursor"
        case .trabajando: return "hammer"
        case .esperandote: return "hand.raised"
        case .problema: return "exclamationmark.triangle"
        }
    }
}

/// Un cuadro de píxel art.
///
/// Acá está la técnica, y no es opcional: **`.interpolation(.none)`**. Sin eso, al escalar los 16×16
/// píxeles a 30 puntos los bordes salen suaves y deja de parecer píxel art. Y el `FillStyle` va con
/// `antialiased: false` por lo mismo: con el valor por defecto, a tamaños no enteros los píxeles salen de
/// distinto grosor.
struct PixelFrameView: View {
    let grid: PixelGrid

    var body: some View {
        Image(size: CGSize(width: grid.columns, height: grid.height),
              label: Text("Pi"), opaque: false, colorMode: .nonLinear) { context in
            for row in 0..<grid.height {
                for column in 0..<grid.columns {
                    guard let color = grid.color(row: row, column: column) else { continue }
                    let rect = CGRect(x: CGFloat(column), y: CGFloat(row), width: 1, height: 1)
                    context.fill(Path(rect), with: .color(Color(nsColor: color.nsColor)),
                                 style: FillStyle(eoFill: false, antialiased: false))
                }
            }
        }
        .interpolation(.none)
        .resizable()
        .aspectRatio(CGFloat(max(grid.columns, 1)) / CGFloat(max(grid.height, 1)), contentMode: .fit)
    }
}
