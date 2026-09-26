import Foundation

/// Dónde vive el gato en la ventana.
///
/// La investigación sobre mascotas de escritorio —mayormente japonesas, que es donde la costumbre está
/// asentada— encontró dos cosas: **abajo a la derecha es la ubicación por defecto más común**, y la
/// ubicación casi siempre **es configurable**, no fija. Así que acá pasa lo mismo: hay una recomendada y
/// se puede cambiar.
///
/// Lo que **no** es una opción, y conviene dejarlo escrito:
///
/// - **La cabecera del chat no tiene lugar.** La barra superior tiene recargar a la izquierda, el título en
///   el centro y cinco controles a la derecha. Meter el gato ahí compite con los controles o pelea con el
///   título.
/// - **La canaleta de los mensajes tampoco.** En el chat estándar el avatar va en la canaleta del lado del
///   mensaje —32 px, el mismo ancho siempre—, pero eso identifica **al autor de cada mensaje**. El estado
///   de acá es del proceso, no de un mensaje, así que repetirlo por mensaje sería mentir.
/// - **Arriba a la derecha no.** Es la zona donde macOS pone las notificaciones.
public enum AvatarPosition: String, Sendable, CaseIterable, Identifiable {
    /// Abajo a la derecha, arriba del compositor. La recomendada, y la que se usa si no hay nada elegido.
    case derecha
    /// Abajo a la izquierda, arriba del compositor. Queda debajo de las burbujas de Pi, que van a la
    /// izquierda: se ve, pero puede confundirse con contenido.
    case izquierda
    /// Al pie de la barra lateral. Nunca toca el historial, y es una esquina de verdad — el mismo lugar
    /// donde una mascota de escritorio se instala.
    case barra
    /// En el chat, **junto al último mensaje de Pi**, en la canaleta de la izquierda.
    ///
    /// Es la posición de un indicador del interlocutor —como el "está escribiendo…" de los chats, que
    /// aparece del lado de los mensajes que llegan— pero con una diferencia a favor: el gato **es** el
    /// interlocutor, así que no hay nada que adivinar.
    ///
    /// La canaleta se reserva en **todas** las filas aunque esté vacía: si no, las burbujas saltarían de
    /// columna cuando aparece el gato. Es la regla que siguen las bibliotecas de chat, y por eso el precio
    /// de esta opción es que el texto tiene 30 puntos menos de ancho desde el primer mensaje.
    case ultimoMensaje
    /// Dentro de la fila del compositor: **a la izquierda del campo donde escribís**.
    ///
    /// No es lo mismo que "abajo a la izquierda", que está en una línea aparte arriba: acá el gato comparte
    /// fila con el campo de texto, así que queda a la altura de lo que estás escribiendo. Es el lugar donde
    /// ya está tu atención cuando estás por escribir, y el estado que más importa en ese momento es
    /// justamente el que el gato muestra.
    case compositor
    /// Arriba de todo, **a la par del botón de nueva conversación**, del lado derecho.
    ///
    /// Es la cabecera de la columna izquierda: el gato queda en el mismo renglón que el botón, pegado al
    /// borde. No toca el historial ni el chat, y está siempre en el mismo lugar — no se mueve con nada.
    case juntoAlBoton

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .derecha: return "Abajo a la derecha"
        case .izquierda: return "Abajo a la izquierda"
        case .barra: return "Al pie de la barra lateral"
        case .ultimoMensaje: return "Junto al último mensaje de Pi"
        case .compositor: return "A la izquierda del compositor"
        case .juntoAlBoton: return "Arriba, junto a Nueva conversación"
        }
    }

    /// Por qué está donde está. Se muestra al elegir, para que la decisión no sea a ciegas.
    public var reason: String {
        switch self {
        case .derecha:
            return "La ubicación por defecto más común en mascotas de escritorio. No compite con el texto, "
                 + "que se lee desde la izquierda, ni con las burbujas de Pi."
        case .izquierda:
            return "Queda debajo de las burbujas de Pi, que van a la izquierda: puede parecer contenido."
        case .barra:
            return "No toca el historial nunca. Es una esquina de verdad, lejos de donde estás leyendo."
        case .ultimoMensaje:
            return "Junto al último mensaje de Pi, como el \"está escribiendo…\" de los chats. Se va con el "
                 + "scroll: si subís a leer, no lo ves. Cuesta 30 puntos de ancho de texto."
        case .compositor:
            return "En la fila del compositor, a la izquierda del campo: a la altura de lo que estás "
                 + "escribiendo. Le saca al campo unos 90 puntos de ancho, y por eso la etiqueta va corta."
        case .juntoAlBoton:
            return "En el mismo renglón que el botón de nueva conversación, pegado al borde derecho de la "
                 + "columna. Siempre en el mismo lugar: no se mueve con el scroll ni con el tamaño del "
                 + "texto. No hay lugar para la etiqueta, así que el estado se lee en el globo del gato."
        }
    }

    /// Si va dentro del chat o en la barra lateral.
    public var livesInChat: Bool { self != .barra }

    /// Si el gato va en la canaleta de un mensaje, en vez de en la zona de estado.
    public var inMessageGutter: Bool { self == .ultimoMensaje }

    /// Si el gato va dentro de la fila del compositor.
    public var inComposer: Bool { self == .compositor }

    /// Si el gato va en el renglón del botón de nueva conversación, arriba de la barra lateral.
    public var inSidebarHeader: Bool { self == .juntoAlBoton }

    /// Si va en la columna de la izquierda, en cualquier lugar.
    public var livesInSidebar: Bool { self == .barra || self == .juntoAlBoton }

    /// Dónde queda escrito el estado. **El gato nunca es la única señal**, así que toda ubicación tiene que
    /// declarar por dónde se lee además del dibujo. Es un dato, no un comentario: hay una verificación que
    /// exige que ninguna ubicación quede sin canal escrito.
    public var textChannel: String {
        switch self {
        case .derecha, .izquierda: return "la etiqueta al lado del gato"
        case .compositor: return "la etiqueta corta al lado del gato"
        case .ultimoMensaje: return "la línea de estado, arriba del compositor"
        case .barra: return "la etiqueta al lado del gato"
        case .juntoAlBoton: return "el globo del gato y el lector de pantalla"
        }
    }

    /// Si la etiqueta va al lado del gato pero **corta**: en el compositor, al lado está el campo de
    /// texto y una etiqueta larga empujaría el campo sin motivo.
    public var usesShortLabel: Bool { self == .compositor }

    /// Si el gato va a la derecha del texto en vez de a la izquierda.
    public var labelFirst: Bool { self == .derecha }

    /// Si la etiqueta va al lado del gato. En la canaleta **no entra**: son 30 puntos, y al lado está el
    /// mensaje. Ahí el estado se escribe en la línea de estado, y el gato no queda siendo la única señal.
    public var showsLabelInline: Bool { !inMessageGutter && !inSidebarHeader }

    /// Si el estado se escribe en la línea de estado, arriba del compositor.
    public var showsStatusLine: Bool { self == .ultimoMensaje }

    /// La que se usa si la preferencia no existe. Ausente = esta.
    public static let recommended: AvatarPosition = .derecha

    /// Lee una posición guardada. Un valor desconocido no rompe: cae en la recomendada.
    public static func from(_ stored: String?) -> AvatarPosition {
        guard let stored, let value = AvatarPosition(rawValue: stored) else { return recommended }
        return value
    }
}
