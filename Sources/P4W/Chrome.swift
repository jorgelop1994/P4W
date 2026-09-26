import AppKit
import SwiftUI

/// Fondo translúcido nativo.
///
/// Regla del plan (§7.3): **vibrancy en el chrome, contenido opaco.** Los materiales de Apple son
/// una capa funcional para navegación, no para la capa de contenido; el texto de cuerpo sobre
/// fondos translúcidos pierde legibilidad (WCAG pide 4.5:1).
struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        // `isEmphasized = false` para no competir con el contenido.
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = isEmphasized
    }
}

/// Velo de la barra superior: **vibrancy con degradado hacia abajo**.
///
/// Sin esto, el contenido que hace scroll pasa por debajo de la barra y choca con el título y los
/// botones: se lee mal y se ve sucio. El material se enmascara con un degradado, así que el
/// desenfoque se desvanece en vez de cortarse con un borde duro.
///
/// Con "Reducir transparencia" activo se degrada a un degradado sólido del color de ventana.
struct TopScrim: View {
    var height: CGFloat = 66
    @EnvironmentObject private var accessibility: AccessibilityObserver
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if accessibility.reduceTransparency {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor),
                             Color(nsColor: .windowBackgroundColor).opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                VibrancyBackground(material: .headerView)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.94), location: 0.42),
                                .init(color: .black.opacity(0.55), location: 0.72),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// Configura la ventana para que la translucidez funcione de verdad.
///
/// Detalles que si se ignoran arruinan el efecto: `isOpaque = false` y `backgroundColor = .clear`
/// son obligatorios para que se vea el material de detrás de la ventana.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        // `isMovableByWindowBackground` se sacó a propósito. Con ese flag, AppKit calcula en **cada
        // evento del mouse** —incluido el scroll— qué zonas son opacas para decidir dónde arrastrar la
        // ventana, y para eso recorre el árbol de vistas completo. Medido con `sample`: el hilo
        // principal aparecía dentro de `platformGlobalWindowDragPreventionPath` →
        // `_regionForOpaqueDescendants`. Con 80 mensajes de markdown eso son miles de vistas
        // recorridas por evento: el cuelgue al desplazarse. La ventana se sigue arrastrando desde su
        // barra superior, que es lo que hace todo el mundo.
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 480)
        installChromeEffect(on: window)
    }

    /// Material **detrás de todo el marco de la ventana**, y eso incluye la barra superior.
    ///
    /// Motivo: con `titlebarAppearsTransparent` la zona de la toolbar no tiene nada detrás, así que
    /// se veía el escritorio sin desenfoque mientras el resto de la app sí tenía vibrancy. Poner el
    /// material en el `themeFrame` cubre también esa franja, sin tocar el layout de SwiftUI.
    private func installChromeEffect(on window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }
        if themeFrame.subviews.contains(where: { $0 is NSVisualEffectView }) { return }
        let effect = NSVisualEffectView(frame: themeFrame.bounds)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        themeFrame.addSubview(effect, positioned: .below, relativeTo: nil)
    }
}

/// Observa los ajustes de accesibilidad y degrada sola (§7.3).
///
/// Apple pide observar la **notificación** de cambio, no solo leer el valor al arrancar: el usuario
/// puede activar "Reducir transparencia" con la app abierta.
@MainActor
final class AccessibilityObserver: ObservableObject {
    @Published private(set) var reduceTransparency = false
    @Published private(set) var reduceMotion = false
    @Published private(set) var increaseContrast = false

    private var observers: [NSObjectProtocol] = []

    init() {
        read()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.read() }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private func read() {
        let display = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        reduceTransparency = display
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Si la ventana se ve y si la app está activa.
///
/// Existe por un motivo concreto: **el gato no puede animarse cuando nadie lo mira**. Apple lo pide en su
/// guía de eficiencia ("dejar de animar cuando la ventana está ocluida"), y acá además el CPU en reposo en
/// 0,0% es una propiedad que ya se ganó y no se negocia por una animación.
final class WindowVisibilityObserver: ObservableObject {
    /// Al menos una parte de la ventana se ve. Tapada, minimizada o en otro espacio: no.
    @Published private(set) var isVisible = true
    @Published private(set) var isActive = true

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            let visible = window.occlusionState.contains(.visible)
            Task { @MainActor in self?.isVisible = visible }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isActive = true }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isActive = false }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Paleta y materiales derivados de la apariencia del sistema.///
/// Nada de colores fijos: los semánticos hacen que claro y oscuro funcionen sin ramas de código.
enum Palette {
    /// Superficie de las burbujas: **casi opaca**, para que el texto se lea sobre lo que haya detrás.
    static func bubble(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .controlBackgroundColor)
            : Color(nsColor: .textBackgroundColor)
    }

    static func userBubble(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.30)
            : Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.34)
    }

    static func codeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.06)
    }

    static func border(_ scheme: ColorScheme, contrast: Bool) -> Color {
        Color(nsColor: .separatorColor).opacity(contrast ? 1 : 0.6)
    }
}
