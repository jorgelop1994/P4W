import Foundation

/// Cuándo mostrar cada cuadro del gato.
///
/// Es lógica pura: recibe los cuadros y un tiempo, y devuelve qué cuadro toca. Así se verifica sin
/// pantalla, sin temporizadores y sin esperar.
///
/// Los cuadros llevan **duración propia**, así que acá no hay ningún FPS: el índice sale de acumular las
/// duraciones. Es lo que permite que un parpadeo dure 0,12 s y una mirada 2,6 s.
public enum CatAnimation {

    /// Cuánto dura una vuelta completa.
    public static func totalDuration(_ frames: [CatArt.Frame]) -> Double {
        frames.reduce(0) { $0 + max(0, $1.seconds) }
    }

    /// Qué cuadro toca en un momento dado. El tiempo se envuelve, así que la animación da vueltas.
    public static func frameIndex(_ frames: [CatArt.Frame], at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        let total = totalDuration(frames)
        // Sin duraciones no hay nada que animar: se queda en el primero en vez de dividir por cero.
        guard total > 0 else { return 0 }

        var remaining = time.truncatingRemainder(dividingBy: total)
        if remaining < 0 { remaining += total }   // tiempos negativos: se envuelven igual de bien
        for (index, frame) in frames.enumerated() {
            let duration = max(0, frame.seconds)
            if remaining < duration { return index }
            remaining -= duration
        }
        return frames.count - 1
    }

    /// El cuadro quieto: el declarado como pose de reposo, o el primero. Es lo que se muestra cuando no se
    /// anima, para que el gato **nunca desaparezca** por tener el movimiento apagado.
    public static func restingIndex(_ frames: [CatArt.Frame]) -> Int {
        frames.firstIndex(where: { $0.isRestingPose }) ?? 0
    }

    /// Si hay que animar. Tres motivos para no hacerlo, y ninguno es opcional:
    ///
    /// - **"Reducir movimiento"** activo: se muestra la pose quieta y listo.
    /// - **La ventana no se ve** (tapada por otra, minimizada): animar ahí es quemar CPU para nadie.
    ///   Es la recomendación de Apple en su guía de eficiencia.
    /// - **La app no está activa**: lo mismo, por menos motivo todavía.
    ///
    /// Y un cuarto caso, que no es accesibilidad sino sentido común: si el estado tiene un solo cuadro, no
    /// hay animación que correr, así que no se enciende ningún temporizador.
    public static func isRunning(state: CatState, frames: [CatArt.Frame], reduceMotion: Bool,
                                 windowVisible: Bool, appActive: Bool) -> Bool {
        guard frames.count > 1 else { return false }
        guard !reduceMotion else { return false }
        return windowVisible && appActive
    }
}
