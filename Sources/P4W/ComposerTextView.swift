import AppKit
import SwiftUI

/// El campo de escribir: un `NSTextView` de verdad, envuelto para SwiftUI.
///
/// **Por qué no un `TextField` de SwiftUI.** Se midió, y el campo de SwiftUI falla en las dos direcciones:
///
/// ```
/// escribir            →  la app no se entera (avisa recién cuando el campo pierde el foco)
/// poner texto desde la app  →  la caja se ve vacía (no refleja el valor del modelo)
/// ```
///
/// La primera mitad es la que borraba texto: la app no sabía que había algo escrito, y cualquier redibujado
/// aplicaba el valor vacío del modelo **encima de lo escrito**. La segunda rompe la recuperación: el borrador
/// vuelve a la app pero **no se ve**, así que la persona cree que se perdió.
///
/// Un `NSTextView` resuelve las dos, porque el texto que se ve **es** el texto del campo:
///
/// 1. Avisa en cada tecla (`textDidChange`), así que el borrador se guarda mientras se escribe.
/// 2. Refleja lo que la app le ponga (`updateNSView`), así que el borrador recuperado **se ve**.
/// 3. Trae su propio deshacer (`allowsUndo`): ⌘Z funciona como en cualquier app, con AppKit agrupando el
///    tecleo, que es lo que recomienda la práctica.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    /// A quién avisarle cuando el alto que necesita el texto cambia.
    var onHeightChange: ((CGFloat) -> Void)?

    private static let lineHeight: CGFloat = 16
    private static let maximumLines: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Deja el campo como tiene que estar. Está aparte y es `static` para que la verificación pueda
    /// comprobar **esta** configuración y no una parecida: ese fue el error de la primera comprobación, que
    /// armó un campo pelado y le preguntó por cosas que configura el compositor.
    static func configure(_ textView: NSTextView, placeholder: String) {
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 1)

        // **El dimensionado, que es lo que hace que el campo tenga ancho.** Sin esto, el `NSTextView` adentro
        // del scroll mide cero y no se ve nada: el ancho lo toma del contenedor y el alto lo pide el campo.
        textView.minSize = NSSize(width: 0, height: lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = true
        // Nada de correcciones automáticas: esto es para hablarle a un agente que escribe código, y las
        // comillas "inteligentes" y el autocorrector ya rompieron suficiente código en el mundo.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityLabel(placeholder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: Self.lineHeight))
        textView.delegate = context.coordinator
        Self.configure(textView, placeholder: placeholder)
        context.coordinator.textView = textView
        context.coordinator.onHeightChange = onHeightChange
        // Se observa **la notificación de AppKit**, no se depende solo del delegado: el delegado no estaba
        // entregando los cambios y el modelo nunca se enteraba de lo que se escribía. La notificación es el
        // mecanismo de abajo, y no se pierde.
        context.coordinator.startObserving(textView)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: Self.lineHeight))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // **Solo si de verdad difiere.** Sin esta guarda, cada redibujado reescribiría el campo con el valor
        // del modelo y se llevaría puesto el cursor — o, si el modelo quedó atrás, el texto.
        if textView.string != text {
            textView.string = text
            context.coordinator.notifyHeightChanged()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        private var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Cada tecla, por la notificación de AppKit.
        func startObserving(_ textView: NSTextView) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: textView, queue: .main
            ) { [weak self] nota in
                guard let self, let tv = nota.object as? NSTextView else { return }
                self.parent.text = tv.string
                self.notifyHeightChanged()
            }
        }
        /// A quién avisarle cuando el alto cambia. Lo pone la vista que contiene al campo.
        var onHeightChange: ((CGFloat) -> Void)?

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// **Cada tecla.** Es lo que el campo de SwiftUI no hacía, y la razón de que el texto pudiera
        /// perderse.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            notifyHeightChanged()
        }

        /// Enter envía; Shift+Enter hace un salto de línea. Explícito, en vez de depender de las reglas del
        /// control.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        /// El alto que necesita el texto, entre un renglón y diez.
        func notifyHeightChanged() {
            guard let textView, let layout = textView.layoutManager,
                  let container = textView.textContainer, let onHeightChange else { return }
            layout.ensureLayout(for: container)
            let usado = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let acotado = min(max(usado.rounded(), ComposerTextView.lineHeight),
                              ComposerTextView.lineHeight * ComposerTextView.maximumLines)
            DispatchQueue.main.async { onHeightChange(acotado) }
        }
    }
}
