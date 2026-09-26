import AppKit
import SwiftUI

/// Diálogos nativos de macOS.
///
/// Se usan `NSAlert` en vez de hojas de SwiftUI porque para esto —pedir un nombre, confirmar un
/// borrado, elegir entre opciones— el sistema ya tiene el comportamiento correcto: teclado, foco,
/// Escape para cancelar, y el texto de los botones en el orden que espera cualquiera.
enum Prompts {

    /// Pide un texto. Devuelve `nil` si se canceló.
    static func ask(_ title: String, message: String, defaultValue: String = "",
                    confirmTitle: String = "Guardar") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        field.placeholderString = "Nombre de la conversación"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Confirma una acción destructiva. El botón destructivo va segundo para que el gesto por
    /// defecto (Enter o Escape) no borre nada.
    static func confirm(_ title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: confirmTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Elige entre opciones. Devuelve el índice, o `nil` si se canceló.
    static func choose(_ title: String, message: String, options: [String]) -> Int? {
        guard !options.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continuar")
        alert.addButton(withTitle: "Cancelar")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 25))
        popup.addItems(withTitles: options)
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.indexOfSelectedItem
    }
}
