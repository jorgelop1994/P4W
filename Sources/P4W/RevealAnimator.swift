import Foundation

/// Lleva el progreso del revelado de texto **fuera de las vistas**.
///
/// Motivo (investigado): los views de un `LazyVStack` son transitorios — solo se mantienen vivos
/// los visibles — y su `@State` se pierde cuando salen de pantalla. En una conversación que
/// scrollea eso hacía que el texto se reiniciara o quedara cortado. Además, el patrón recomendado
/// para streaming de LLM en SwiftUI es justamente no guardar el texto por token en el view.
///
/// Es un objeto del modelo: sobrevive al reciclado de vistas y hay una sola animación, la del
/// mensaje que está llegando ahora.
@MainActor
final class RevealAnimator: ObservableObject {

    /// Cuántos caracteres se están mostrando del mensaje en curso.
    @Published private(set) var count = 0
    /// A qué mensaje corresponde ese progreso.
    @Published private(set) var itemID: String?

    private var timer: Timer?
    private var target = 0

    /// Avance de un tick. Función pura para poder verificarla: nunca retrocede, nunca se pasa,
    /// y se acelera cuando queda mucho por revelar (revelar 5.000 caracteres de a uno sería
    /// una tortura).
    nonisolated static func advance(current: Int, target: Int) -> Int {
        guard current < target else { return target }
        let remaining = target - current
        return current + max(1, remaining / 10)
    }

    /// Se llama cuando cambia el mensaje en curso o su texto.
    func update(itemID: String?, targetLength: Int, isStreaming: Bool) {
        let changedItem = itemID != self.itemID
        self.itemID = itemID
        self.target = targetLength

        if changedItem || !isStreaming {
            // Mensaje nuevo, o ya terminó: se muestra completo y se corta la animación.
            count = targetLength
            stop()
            return
        }
        if count > targetLength { count = targetLength }
        startIfNeeded()
    }

    func reset() {
        stop()
        itemID = nil
        target = 0
        count = 0
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.028, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.count = Self.advance(current: self.count, target: self.target)
                if self.count >= self.target { self.stop() }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
