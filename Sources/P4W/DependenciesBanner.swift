import P4WCore
import SwiftUI

/// El aviso de dependencias, dentro de la app.
///
/// Dos formas, porque son dos situaciones distintas:
///
/// - **Falta algo obligatorio**: un panel que no se puede descartar. Sin `pi` la app no puede abrir nada,
///   así que dejar silenciarlo sería esconder el problema en vez de resolverlo.
/// - **Falta algo recomendado u opcional**: una línea discreta, con su ✕. Se avisa una vez y se puede
///   descartar, porque la app funciona igual.
///
/// Va también en el primer arranque: en una Mac nueva no hay índice ni conversaciones, y esta es la
/// información que hace falta justo ahí.
struct DependenciesBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let issues = model.visibleDependencyIssues
        if !issues.isEmpty {
            let blocking = issues.filter { $0.level == .obligatorio }
            if !blocking.isEmpty {
                blockingPanel(blocking)
            } else {
                recommendationLine(issues)
            }
        }
    }

    /// Lo que impide usar la app. Sin ✕ a propósito.
    private func blockingPanel(_ items: [DependencyItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(items.count == 1 ? "Falta algo necesario para que P4W funcione"
                                      : "Faltan \(items.count) cosas necesarias para que P4W funcione")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
                Button("Volver a revisar") { model.checkDependencies() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.title): \(item.detail)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(item.fix)
                        .font(.system(size: 10.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    /// Lo que conviene pero no impide nada. Una línea, y se puede descartar.
    private func recommendationLine(_ items: [DependencyItem]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(items.map { "\($0.title): \($0.detail)" }.joined(separator: " · "))
                .font(.system(size: 10))
                .lineLimit(1)
                .help(items.map { $0.fix }.joined(separator: "\n\n"))
            Spacer(minLength: 4)
            // Descartar descarta **ese** aviso: si mañana falta otra cosa, vuelve a aparecer.
            ForEach(items) { item in
                Button {
                    model.dismissDependency(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("No volver a avisar sobre \(item.title)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }
}
