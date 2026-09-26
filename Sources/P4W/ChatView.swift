import SwiftUI
import P4WCore

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var accessibility: AccessibilityObserver
    @Environment(\.colorScheme) private var scheme

    /// Si la persona subió a leer, se deja de seguir el final.
    @State private var followsBottom = true
    @State private var viewportHeight: CGFloat = 0

    /// Ancho de la columna de lectura. La investigación es consistente: el texto de cuerpo se lee
    /// cómodo entre 60 y 80 caracteres por línea, y una respuesta estirada al ancho de la ventana
    /// cansa. 720 pt deja el markdown cómodo y, a la vez, permite tablas y código anchos con scroll.
    private static let columnWidth: CGFloat = 720

    /// A qué distancia del fondo se considera que la persona "sigue" la conversación.
    /// Los clientes que lo implementan usan entre 24 y 150 px; 60 es el punto medio.
    private static let followThreshold: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            if model.showsEmptyConversationPlaceholder {
                NewConversationPlaceholder()
            } else if model.current == nil && model.items.isEmpty {
                EmptyStateView()
            } else {
                transcript
            }
            if !model.dialogs.isEmpty { DialogStack() }
            if !model.extensionStatuses.isEmpty {
                ExtensionStatusLine(statuses: model.extensionStatuses)
            }
            if let note = model.statusNote {
                StatusLine(text: note)
            }
            if let error = model.lastError {
                ErrorBanner(text: error)
            }
            // El aviso de dependencias va arriba de todo lo demás: si falta `pi`, es lo primero que hay
            // que ver y nada de lo de abajo tiene sentido todavía.
            DependenciesBanner()
            // El gato va justo arriba del compositor: es lo último que se mira antes de escribir, y ahí su
            // estado es el que importa. En la canaleta no se dibuja acá — pero **la etiqueta sí**: el gato
            // nunca puede quedar siendo la única señal. En la barra lateral no va ninguna de las dos.
            let position = model.avatarPosition
            if position.inMessageGutter {
                CatStateLine(state: model.catState)
            } else if position.inSidebarHeader {
                // El gato está arriba, junto al botón: acá no se dibuja nada, y tampoco hay línea de estado
                // porque el chat quedaría con una señal que no le corresponde.
                EmptyView()
            } else if position.inComposer {
                // El gato y su etiqueta corta van en la fila del campo: no se repite acá.
                EmptyView()
            } else if position.livesInChat {
                CatAvatarView(state: model.catState)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
            }
            // Y la explicación de que se puede mover, una sola vez.
            if position.livesInChat && !position.inComposer && model.showsAvatarHint {
                AvatarHint()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            ComposerView()
        }
    }

    /// El último mensaje de Pi: es al lado de ese que va el gato cuando se elige la canaleta.
    private var lastAssistantID: String? {
        model.items.last { $0.author == .assistant }?.id
    }

    private var showsGutter: Bool { model.avatarPosition.inMessageGutter }

    /// Cuánto texto se muestra de un mensaje. Sacado del cuerpo de la vista: adentro del `ForEach` el
    /// compilador no podía con la expresión entera.
    private func revealedCount(for item: ChatItem) -> Int {
        model.reveal.itemID == item.id ? model.reveal.count : item.text.count
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.isLoadingHistory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Cargando la rama activa de la conversación…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 20)
                    }
                    if model.hasOlderHistory {
                        // La conversación se abre por el final: pedir lo anterior es explícito y no
                        // cuesta nada hasta que se pide.
                        HStack {
                            Spacer()
                            Button {
                                model.loadOlder()
                            } label: {
                                HStack(spacing: 5) {
                                    if model.isLoadingOlder {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    Text(model.isLoadingOlder ? "Cargando…" : "Cargar mensajes anteriores")
                                        .font(.system(size: 10.5))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .disabled(model.isLoadingOlder)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(model.items) { item in
                        HStack(alignment: .top, spacing: 6) {
                            if showsGutter {
                                MessageGutter(cat: item.id == lastAssistantID,
                                              state: model.catState,
                                              width: model.avatarSize.points)
                            }
                            // Sin `.id` extra: el `ForEach` ya identifica por `item.id`, y un `.id`
                            // puesto encima puede anular la optimización de la pila perezosa.
                            MessageRow(item: item, revealed: revealedCount(for: item))
                        }
                    }
                    // Centinela del fondo: mide dónde está el final respecto del viewport.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomEdgeKey.self,
                                    value: geometry.frame(in: .named("chatScroll")).minY
                                )
                            }
                        )
                }
                .padding(.horizontal, 22)
                .padding(.top, 58)          // deja libre la franja de la barra superior
                .padding(.bottom, 18)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .coordinateSpace(name: "chatScroll")
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
                }
            )
            .onPreferenceChange(BottomEdgeKey.self) { bottomEdge in
                // Si el fondo del contenido está dentro del viewport (con margen), se sigue la
                // conversación. Si la persona subió a leer, se deja de seguir: pelear con el scroll
                // es el error clásico de las interfaces de chat.
                let following = bottomEdge <= viewportHeight + Self.followThreshold
                if following != followsBottom { followsBottom = following }
            }
            .onChange(of: model.items.count) { _, _ in
                // Al enviar siempre se vuelve al final, aunque se estuviera leyendo más arriba.
                if model.items.last?.author == .user { followsBottom = true }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: model.items.last?.text) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: model.scrollAnchor) { _, anchor in
                // Al anteponer historial, se vuelve al mensaje que se estaba mirando: el texto no salta.
                guard let anchor, model.items.contains(where: { $0.id == anchor }) else { return }
                proxy.scrollTo(anchor, anchor: .top)
                model.scrollAnchor = nil
            }
            .overlay(alignment: .bottom) {
                if !followsBottom {
                    JumpToBottomButton {
                        followsBottom = true
                        scrollToBottom(proxy, animated: true)
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard followsBottom else { return }
        if accessibility.reduceMotion || !animated {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// Posición del fondo del contenido dentro del scroll, para saber si estamos siguiendo.
struct BottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Aparece solo cuando la persona dejó de seguir el final: así sabe que hay algo nuevo sin que se
/// le mueva la pantalla debajo de los ojos.
struct JumpToBottomButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Ir al final")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MessageRow: View {
    let item: ChatItem
    /// Caracteres a mostrar. Sale del modelo, no del estado de la vista.
    let revealed: Int
    @State private var hovering = false

    var body: some View {
        content
            .overlay(alignment: item.author == .user ? .bottomLeading : .bottomTrailing) {
                if hovering, !item.text.isEmpty, item.author != .notice {
                    MessageActions(item: item)
                        .offset(y: 10)
                        .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contextMenu {
                if !item.text.isEmpty {
                    Button("Copiar mensaje") { copy(item.text) }
                }
                if !item.thinking.isEmpty {
                    Button("Copiar el pensamiento") { copy(item.thinking) }
                }
                ForEach(item.tools) { tool in
                    if !tool.output.isEmpty {
                        Button("Copiar salida de \(tool.name)") { copy(tool.output) }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch item.author {
        case .notice:
            NoticeView(text: item.text, errored: item.errored)
        case .user:
            HStack {
                Spacer(minLength: 60)
                UserBubble(item: item)
            }
        case .assistant:
            HStack {
                AssistantBubble(item: item, revealed: revealed)
                Spacer(minLength: 60)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Acciones de un mensaje. Aparecen al pasar el mouse, para no ensuciar la lectura — es el patrón
/// que usan las interfaces de chat buenas — y además están en el menú contextual, que es lo que
/// espera cualquiera que use macOS.
struct MessageActions: View {
    let item: ChatItem
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)

            Button {
                NSPasteboard.general.clearContents()
                // Se copia el markdown de origen, no el texto ya formateado: así se puede pegar en
                // otro lado con su estructura.
                NSPasteboard.general.setString(item.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                    Text(copied ? "copiado" : "copiar")
                        .font(.system(size: 9.5))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color.accentColor : Color.secondary)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.thinking, forType: .string)
            } label: {
                Image(systemName: "brain")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(item.thinking.isEmpty ? 0 : 1)
            .disabled(item.thinking.isEmpty)
            .help("Copiar el pensamiento")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

struct UserBubble: View {
    let item: ChatItem
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var accessibility: AccessibilityObserver

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let queued = item.queued {
                // Igual que en Pi: el mensaje espera turno y se dice, en vez de desaparecer sin
                // explicación hasta que le toque.
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(queued.label)
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)
            }
            if !item.attachments.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(item.attachments) { attachment in
                        AttachmentChip(attachment: attachment)
                    }
                }
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(Palette.userBubble(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.border(scheme, contrast: accessibility.increaseContrast), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

struct AssistantBubble: View {
    let item: ChatItem
    let revealed: Int
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var accessibility: AccessibilityObserver

    private var hasActivity: Bool {
        !item.thinking.isEmpty || !item.tools.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // La actividad (pensamiento y herramientas) va **fuera** del globo de la respuesta.
            // No es una separación técnica —el parseo nunca se contaminó, son campos distintos—
            // sino de lectura: la respuesta es un documento y necesita su propio aire, sin
            // mezclarse con monoespaciado de herramientas.
            if hasActivity {
                ActivityRail(item: item)
            }

            if !item.text.isEmpty {
                StreamingText(text: item.text, isStreaming: item.isStreaming, revealed: revealed)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Palette.bubble(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Palette.border(scheme, contrast: accessibility.increaseContrast),
                                    lineWidth: 1)
                    )
                    .cornerRadius(12)
            } else if item.isStreaming && !hasActivity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("pensando…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if item.errored, let message = item.errorMessage {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.09))
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Riel de actividad de un turno: lo que Pi hizo antes de responder.
///
/// Colapsado es **una línea** ("pensó 132 caracteres · 2 herramientas"), así la conversación se lee
/// como una sucesión de respuestas y no como un registro de ejecución. Se expande a demanda, y
/// mientras todavía no hay respuesta se abre solo, porque en ese momento el pensamiento *es* lo
/// que está pasando.
/// La canaleta de la izquierda, donde va el gato cuando se elige esa ubicación.
///
/// Se reserva en **todas** las filas aunque esté vacía: si no, las burbujas saltarían de columna al
/// aparecer el gato. Es la regla que siguen las bibliotecas de chat, y el motivo de que esa ubicación
/// cueste ancho de texto desde el primer mensaje.
private struct MessageGutter: View {
    let cat: Bool
    let state: CatState
    /// El ancho lo fija el tamaño del gato: si no, al agrandarlo quedaría pisando el mensaje.
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: width, height: 1)
            if cat { CatAvatarView(state: state, style: .catOnly) }
        }
        .frame(width: width)
    }
}

struct ActivityRail: View {
    let item: ChatItem
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    /// Si la persona lo abrió o cerró a mano, no se le toca más.
    @State private var userToggled = false

    private var summary: String {
        var parts: [String] = []
        if !item.thinking.isEmpty {
            parts.append(item.isStreaming && item.text.isEmpty
                         ? "pensando… \(item.thinking.count) caracteres"
                         : "pensó \(item.thinking.count) caracteres")
        }
        let toolCount = item.tools.count
        if toolCount > 0 {
            parts.append("\(toolCount) herramienta\(toolCount == 1 ? "" : "s")")
        }
        if item.tools.contains(where: { $0.isError }) { parts.append("con error") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                userToggled = true
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    if item.isStreaming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                    }
                    Text(summary)
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !item.thinking.isEmpty {
                    Text(item.thinking)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.codeBackground(scheme).opacity(0.55))
                        .cornerRadius(6)
                }
                if !item.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.tools) { tool in
                            ToolChip(tool: tool)
                        }
                    }
                }
            }
        }
        .padding(.leading, 9)
        .padding(.vertical, 5)
        .padding(.trailing, 8)
        .background(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor.opacity(item.isStreaming ? 0.55 : 0.28))
                    .frame(width: 2)
                Color.primary.opacity(0.028)
            }
        )
        .cornerRadius(6)
        .onAppear {
            // Al aparecer sin respuesta todavía, se muestra el pensamiento en vivo.
            if !userToggled { expanded = item.text.isEmpty && item.isStreaming }
        }
        .onChange(of: item.text.isEmpty) { _, isEmpty in
            guard !userToggled else { return }
            expanded = isEmpty && item.isStreaming
        }
    }
}

/// La burbuja de pensamiento aparece **siempre que haya pensamiento**, sin importar el modelo ni
/// el nivel configurado: se decide por los datos, no por suposiciones (§7.1).
struct ThinkingBubble: View {
    let text: String
    let streaming: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text(streaming ? "pensando… \(text.count) caracteres" : "pensó \(text.count) caracteres")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.codeBackground(scheme).opacity(0.6))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}

struct ToolChip: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !tool.output.isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if tool.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(tool.isError ? .red : .green)
                    }
                    Text(tool.label)
                        .font(.system(size: 10.5, weight: .medium))
                    if !tool.argumentSummary.isEmpty {
                        Text(tool.argumentSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !tool.output.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(tool.output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .background(Color.primary.opacity(0.05))
                .cornerRadius(5)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045))
        .cornerRadius(7)
    }
}

struct AttachmentChip: View {
    let attachment: AttachmentRef

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.isImage ? "photo" : (attachment.stillExists ? "doc" : "doc.badge.ellipsis"))
                .font(.system(size: 9))
            Text(attachment.fileName)
                .font(.system(size: 10))
                .lineLimit(1)
            if !attachment.isImage && !attachment.stillExists {
                Text("no encontrado")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07))
        .cornerRadius(6)
    }
}

/// Diálogos de extensión. Un diálogo pendiente es exactamente lo que Pi reporta como `blocked`,
/// así que se muestran como una tarjeta accionable y no como un modal perdido.
struct DialogStack: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.dialogs, id: \.id) { dialog in
                DialogCard(dialog: dialog)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }
}

struct DialogCard: View {
    let dialog: DialogRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dialog.prompt.isEmpty ? dialog.method : dialog.prompt)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            switch dialog.kind {
            case .confirm:
                HStack(spacing: 8) {
                    Button("Confirmar") { model.respond(to: dialog, confirmed: true) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancelar") { model.respond(to: dialog, confirmed: false) }
                }
            case .select:
                ForEach(dialog.options, id: \.self) { option in
                    Button(option) { model.respond(to: dialog, value: option) }
                        .buttonStyle(.link)
                }
            case .input, .editor:
                HStack(spacing: 6) {
                    TextField(dialog.placeholder ?? "", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.respond(to: dialog, value: text) }
                    Button("Enviar") { model.respond(to: dialog, value: text) }
                }
            case .none:
                Button("Ignorar") { model.respond(to: dialog, cancelled: true) }
            }

            if dialog.kind != .confirm {
                Button("Cancelar") { model.respond(to: dialog, cancelled: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Palette.bubble(scheme))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.55), lineWidth: 1))
        .cornerRadius(10)
    }
}

struct NoticeView: View {
    let text: String
    let errored: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: errored ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(errored ? Color.red : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}

/// Lo que las extensiones reportan en su pie, en una interfaz gráfica.
///
/// No es decorativo: por ejemplo la extensión de caché de prefijo reporta acá su **tasa de acierto**
/// ("Cache 97.3%"), que es un ahorro medible sobre los tokens de entrada. Pi lo muestra en el pie de su
/// TUI con `setStatus`, y P4W ya recibe esos avisos: esto los hace visibles.
struct ExtensionStatusLine: View {
    let statuses: [(key: String, text: String)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(statuses, id: \.key) { status in
                HStack(spacing: 3) {
                    Image(systemName: symbol(for: status.key))
                        .font(.system(size: 8))
                    Text(status.text)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
        .help("Lo que reportan las extensiones de Pi. Se toma de sus avisos de estado.")
    }

    private func symbol(for key: String) -> String {
        let lowered = key.lowercased()
        if lowered.contains("cache") { return "arrow.triangle.2.circlepath" }
        if lowered.contains("mcp") { return "puzzlepiece.extension" }
        if lowered.contains("telegram") { return "paperplane" }
        return "info.circle"
    }
}

struct StatusLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.10))
    }
}

/// Conversación recién creada: todavía no hay nada en disco, así que no se puede "cargar" nada.
struct NewConversationPlaceholder: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Conversación nueva")
                .font(.system(size: 14, weight: .medium))
            Text("Escribí abajo para empezar. Se guarda sola en el historial de Pi, con el perfil \(model.selectedProfileName).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Elegí una conversación")
                .font(.system(size: 14, weight: .medium))
            Text("P4W muestra las conversaciones que Pi ya tiene guardadas en esta máquina, y solo mantiene en memoria las que estás usando.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if !model.environmentNote.isEmpty {
                Text(model.environmentNote)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
