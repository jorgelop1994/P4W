import P4WCore
import SwiftUI

/// La línea que avisa que hay una versión nueva.
///
/// Mismo lenguaje visual que el aviso de dependencias, y por el mismo motivo: es algo que conviene saber y
/// que **no bloquea nada**. Tres reglas, que no se deciden acá sino en `UpdateNotice`:
///
/// 1. Aparece **solo** cuando hay algo nuevo. Ni "al día" ni "no se pudo consultar" se muestran.
/// 2. **Nunca mientras Pi trabaja** — es el momento en que la persona espera otra cosa.
/// 3. Descartarla la recuerda **por versión**: una más nueva vuelve a avisar.
struct UpdateNoticeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.showsUpdateNotice, let update = model.availableUpdate {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9))
                // El texto se arma **antes** de entrar al `Text` localizado: interpolar un tipo propio ahí
                // produce un aviso del compilador, y el aviso tiene razón.
                Text("Hay una versión nueva: " + update.version.description)
                    .font(.system(size: 11))
                Button("Descargar") {
                    // Se abre el `.dmg` del release, no una página: un clic en vez de dos.
                    NSWorkspace.shared.open(update.downloadURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                Button {
                    model.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("No avisar más de la " + update.version.description
                      + ". Una versión más nueva sí va a avisar.")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }
    }
}
