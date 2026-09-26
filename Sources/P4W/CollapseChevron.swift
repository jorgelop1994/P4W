import P4WCore
import SwiftUI

/// El botón de plegar, **uno solo para todo el sidebar**.
///
/// Ya existía para los spaces (chevron de 8 puntos, 10 de ancho, gris). Lo que se agrega es que ahora lo
/// usan también las secciones y los grupos del historial: dos mecanismos de plegado en la misma columna
/// serían un defecto, no una mejora.
///
/// Y el estado **se guarda**: antes vivía en un `@State` de la vista y cada arranque empezaba con todo
/// desplegado, con lo cual plegar era media función.
struct CollapseChevron: View {
    let sectionKey: String
    /// Para la etiqueta de accesibilidad y el globo: "Sugerencias", "el space Trabajo"…
    let title: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collapsed: Bool { model.isCollapsed(sectionKey) }

    var body: some View {
        Button {
            // Con "Reducir movimiento" no hay transición: aparece y listo. Con movimiento, un desvanecido
            // corto, que es lo que hace que se entienda que el contenido de arriba se fue *ahí*.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                model.toggleSection(sectionKey)
            }
        } label: {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Un triángulo dibujado no alcanza: el estado tiene que poder leerse sin verlo.
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "plegada" : "desplegada")
        .help(collapsed ? "Mostrar \(title)" : "Ocultar \(title)")
    }
}

/// El contador que va al lado del título de una sección.
///
/// Está **siempre**, plegada o no. Plegar puede esconder el contenido, nunca la información de que hay
/// algo: una sección plegada y vacía tiene que verse distinta de una plegada con cosas adentro.
struct SectionCount: View {
    @Environment(\.colorScheme) private var scheme
    let count: Int
    var body: some View {
        Text(SidebarContent.countLabel(count))
            .font(.system(size: 11))
            .foregroundStyle(Palette.info(scheme))
    }
}

/// El título de una sección del sidebar, con su chevron y su contador.
struct SectionTitle: View {
    let sectionKey: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            CollapseChevron(sectionKey: sectionKey, title: title)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SectionCount(count: count)
        }
    }
}
