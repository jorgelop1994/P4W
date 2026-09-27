import SwiftUI
import P4WCore

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var accessibility: AccessibilityObserver
    @State private var isDropTarget = false
    /// El alto del campo: lo mide el propio campo y lo pide acá.
    @State private var fieldHeight: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            // Atajos ocultos, espejo del estándar de Pi: ⌥↵ seguimiento, ⌥↑ devolver al editor.
            // Se declaran acá porque un `TextField` de SwiftUI no distingue modificadores en onSubmit.
            Group {
                Button("") { model.sendFollowUp() }
                    .keyboardShortcut(.return, modifiers: .option)
                Button("") { model.dequeue() }
                    .keyboardShortcut(.upArrow, modifiers: .option)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            if model.workingHint != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(model.workingHint ?? "")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                    if model.hasQueuedMessages {
                        Button("Devolver al editor") { model.dequeue() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            if !model.attachments.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(model.attachments) { attachment in
                        HStack(spacing: 5) {
                            AttachmentChip(attachment: attachment)
                            Button {
                                model.attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                // El gato va **afuera de la barra**, pegada a su izquierda y a su misma altura: la barra
                // conserva su fondo y su borde, y el gato queda al lado, no adentro. Comparte fila con el
                // campo, así que está a la altura de lo que estás escribiendo.
                if model.avatarPosition.inComposer {
                    CatAvatarView(state: model.catState, style: .catWithShortLabel)
                        .padding(.bottom, 2)
                }
                inputBar
            }
            // Ancho completo y alineado a la izquierda: si no, la fila se centra y la barra parece empezar
            // en el medio de la ventana.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    /// La barra de escritura: el clip, el campo y el botón, con su fondo y su borde. Es una vista aparte
    /// para que el gato pueda quedar **fuera** de ella y no adentro.
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                pickFiles()
            } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Adjuntar archivos. Se referencian por ruta; no se copian.")

                // Un `NSTextView` de verdad, no un `TextField`: ver `ComposerTextView` para el porqué
                // medido. Avisa en cada tecla —así el borrador se guarda mientras se escribe— y refleja lo
                // que la app le ponga, así que un borrador recuperado **se ve**.
                ComposerTextView(
                    text: Binding(get: { model.draft }, set: { model.draftChanged($0) }),
                    placeholder: "Escribile a Pi…  (Enter para enviar, Shift+Enter para salto de línea)",
                    onSubmit: { model.send() },
                    onHeightChange: { alto in fieldHeight = alto }
                )
                .frame(height: fieldHeight)

                if model.isSending {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Detener")
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.draft.isEmpty && model.attachments.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Enviar")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.bubble(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isDropTarget ? Color.accentColor
                            : Palette.border(scheme, contrast: accessibility.increaseContrast),
                            lineWidth: isDropTarget ? 2 : 1)
            )
            .cornerRadius(10)
        .background(LayoutProbe.attachment("barra de escritura"))
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Los archivos se referencian por ruta (como @ruta en la terminal). Las imágenes viajan incrustadas."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.addAttachment(from: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.addAttachment(from: url) }
            }
        }
        return handled
    }
}

/// Envoltura simple de filas para los chips de adjuntos, sin depender de un layout externo.
struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
            Spacer(minLength: 0)
        }
    }
}
