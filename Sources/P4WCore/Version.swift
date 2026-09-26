import Foundation

/// La versión de P4W, en **un solo lugar**.
///
/// Antes vivía escrita en `scripts/build-app.sh`, que la copiaba al `Info.plist`. Con el aviso de
/// actualizaciones eso dejó de alcanzar: la app necesita saber su propia versión en tiempo de ejecución, y
/// dos copias del mismo número terminan separándose. Ahora el script la lee de acá.
public enum P4WVersion {
    /// Sube con cada release. Es el número que aparece en el `Info.plist` y contra el que se compara la
    /// última versión publicada.
    public static let current = "0.2.0"

    /// La versión ya convertida, para comparar. Si algún día esta cadena deja de parsear, la app no dice
    /// nada en vez de decir cualquier cosa.
    public static var release: ReleaseVersion? { ReleaseVersion(current) }
}
