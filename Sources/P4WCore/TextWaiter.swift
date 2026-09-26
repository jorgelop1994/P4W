import Foundation

/// Espera el final de un run **y** junta el texto del asistente.
///
/// Existe por un motivo concreto: el patrón "asignar `onEvent` y esperar" tiende a escribirse capturando
/// variables mutables, y eso es una carrera de datos real —el cierre corre en el hilo de eventos mientras
/// la otra parte lee— y será error en Swift 6. Acá el estado compartido está detrás de un candado, y quien
/// espera nunca toca el estado directamente.
///
/// La interpretación de los eventos vive acá y no en cada llamador: el texto definitivo es el de
/// `message_end`, no el acumulado de los deltas, porque un delta puede llegar cortado.
public final class TextWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var _settled = false
    private var _text = ""
    private var _errored = false

    public init() {}

    /// Para asignar directamente a `onEvent`.
    public func apply(_ event: PiEvent) {
        switch event {
        case .agentSettled:
            lock.lock(); _settled = true; lock.unlock()
        case .delta(let delta, _) where delta.kind == .text:
            lock.lock(); _text += delta.text; lock.unlock()
        case .messageEnd(let role, let text, _, _, let error, _) where role == "assistant":
            lock.lock()
            // El texto del evento es el más completo: si el delta se cortó, esto lo corrige.
            if !text.isEmpty { _text = text }
            if error != nil { _errored = true }
            lock.unlock()
        default:
            break
        }
    }

    /// Espera el fin del run. Devuelve si terminó de verdad o se agotó el tiempo.
    @discardableResult
    public func waitSettled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if settled { return true }
            usleep(250_000)
        }
        return settled
    }

    public var settled: Bool { lock.lock(); defer { lock.unlock() }; return _settled }
    public var text: String { lock.lock(); defer { lock.unlock() }; return _text }
    public var errored: Bool { lock.lock(); defer { lock.unlock() }; return _errored }
}
