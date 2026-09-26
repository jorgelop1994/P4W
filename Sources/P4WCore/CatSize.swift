import Foundation

/// Cuánto mide el gato en pantalla.
///
/// Los tamaños son **múltiplos exactos del cuadro**, y no es un detalle estético: el arte es de 16×16, así
/// que a 32 puntos cada píxel mide 2 puntos, a 48 mide 3 y a 64 mide 4. Con un tamaño que no sea múltiplo,
/// unos píxeles salen de 2 puntos y otros de 3, y el gato se ve sucio por más que el dibujo esté bien.
/// Por eso no hay nada entre 32 y 48: el escalado entero manda.
public enum CatSize: String, Sendable, CaseIterable, Identifiable {
    case chico
    case mediano
    case grande

    public var id: String { rawValue }

    /// El lado del cuadrado, en puntos. Siempre un múltiplo del ancho del cuadro.
    public var points: CGFloat {
        switch self {
        case .chico: return 32
        case .mediano: return 48
        case .grande: return 64
        }
    }

    public var label: String {
        switch self {
        case .chico: return "Chico (\(Int(points)))"
        case .mediano: return "Mediano (\(Int(points)))"
        case .grande: return "Grande (\(Int(points)))"
        }
    }

    /// Cuántos puntos mide cada píxel del dibujo. Entero por construcción.
    public var pixelPoints: Int { Int(points) / CatArt.gridSide }

    /// El que se usa si no hay nada elegido. Mediano: el chico se veía pequeño.
    public static let recommended: CatSize = .mediano

    /// Lee un tamaño guardado. Un valor desconocido no rompe: cae en el recomendado.
    public static func from(_ stored: String?) -> CatSize {
        guard let stored, let value = CatSize(rawValue: stored) else { return recommended }
        return value
    }
}
