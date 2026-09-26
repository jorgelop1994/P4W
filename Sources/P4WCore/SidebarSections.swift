import Foundation

/// Las secciones del sidebar y sus claves de plegado.
///
/// Una sola clave por sección, en un solo conjunto. Es la misma idea que el plegado de los spaces, que ya
/// existía: lo que se agrega es que ahora **hay más secciones**, que el estado **se guarda**, y que el
/// número de lo que hay adentro se ve aunque esté plegada.
public enum SidebarSection {
    public static let sugerencias = "sugerencias"
    public static let espacios = "espacios"
    public static let historial = "historial"

    public static func space(_ id: String) -> String { "space:\(id)" }
    public static func project(_ name: String) -> String { "proyecto:\(name)" }
}

/// Lo que se muestra según lo que esté plegado. Es lógica pura: no toca vistas, así que se verifica con
/// datos fabricados.
public enum SidebarContent {

    /// Si una sección está plegada.
    public static func isCollapsed(_ key: String, collapsed: Set<String>) -> Bool {
        collapsed.contains(key)
    }

    /// Las conversaciones de un grupo, según si el grupo está plegado.
    ///
    /// Devuelve **lista vacía** cuando está plegado. No es un detalle: es lo que hace que plegar sirva para
    /// algo — la columna no construye esas filas, en vez de construirlas y esconderlas.
    public static func visibleSessions(_ sessions: [String], group key: String,
                                       collapsed: Set<String>) -> [String] {
        isCollapsed(key, collapsed: collapsed) ? [] : sessions
    }

    /// El texto del contador que se muestra al lado del título.
    ///
    /// Siempre está, plegado o no: plegar puede esconder el contenido, **nunca la información de que hay
    /// algo**. Una sección plegada y vacía tiene que verse distinta de una plegada con cosas adentro.
    public static func countLabel(_ count: Int) -> String { "\(count)" }

    /// Las tres secciones de arriba, en orden, con su título. El historial va último.
    public static let headers: [(key: String, title: String)] = [
        (SidebarSection.sugerencias, "SUGERENCIAS"),
        (SidebarSection.espacios, "SPACES"),
        (SidebarSection.historial, "SIN SPACE"),
    ]
}
