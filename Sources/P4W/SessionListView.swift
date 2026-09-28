import SwiftUI
import P4WCore

struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.newConversation()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .medium))
                        Text("Nueva conversación")
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(model.isNewConversation ? Palette.userBubble(scheme) : Color.primary.opacity(0.06))
                .cornerRadius(7)
                .help("Empezar una conversación nueva (⌘N)")

                // El gato comparte renglón con el botón y queda pegado al borde: **afuera** del recuadro del
                // botón, a su misma altura. El botón se encoge para dejarle lugar, no al revés.
                if model.avatarPosition.inSidebarHeader {
                    CatAvatarView(state: model.catState, style: .catOnly)
                        .help("Qué está haciendo Pi: \(model.catState.label)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 42)          // deja libre la franja de la barra superior

            if model.avatarPosition.livesInSidebar && model.showsAvatarHint {
                AvatarHint()
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Buscar conversaciones", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            Divider().opacity(0.4)

            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView()
            } else if model.sessions.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Leyendo conversaciones…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Modo simple: nada de sugerencias ni de spaces. Lo que esté en un space **no se
                        // pierde**: la lista de abajo muestra todas las conversaciones.
                        if model.interfaceMode.showsSuggestions { SuggestionsSection() }
                        if model.interfaceMode.showsSpaces { SpacesSection() }

                        // El historial: el encabezado se pliega entero, y cada grupo por proyecto
                        // también. Con 476 conversaciones en ~15 proyectos, el grupo es lo que más se usa.
                        if model.interfaceMode.showsSectionHeaders {
                            HStack(spacing: 4) {
                                SectionTitle(sectionKey: SidebarSection.historial,
                                             title: "SIN SPACE",
                                             count: model.sessionsOutsideSpaces.count)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                        }

                        let _ = LayoutProbe.noteHistory(
                            built: !model.isCollapsed(SidebarSection.historial))
                        if !model.interfaceMode.groupsByProject {
                            // **La lista del modo simple.** Todas las conversaciones por fecha, incluidas las
                            // que están en un space: esconder los spaces no puede esconder una conversación.
                            ForEach(model.sessions) { session in
                                SessionRow(session: session,
                                           selected: session.path == model.current?.path)
                                .onTapGesture { model.open(session) }
                                .contextMenu { SessionActions(session: session) }
                            }
                        } else if !model.isCollapsed(SidebarSection.historial) {
                            ForEach(groupedByProject, id: \.project) { group in
                                HStack(spacing: 4) {
                                    // El grupo se identifica por su **nombre**, no por su posición: si se
                                    // agregara un proyecto nuevo, las claves viejas siguen valiendo.
                                    CollapseChevron(sectionKey: SidebarSection.project(group.title),
                                                    title: group.title)
                                    Text(group.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.info(scheme))
                                    SectionCount(count: group.sessions.count)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .padding(.bottom, 1)

                                if !model.isCollapsed(SidebarSection.project(group.title)) {
                                    ForEach(group.sessions) { session in
                                        SessionRow(session: session,
                                                   selected: session.path == model.current?.path)
                                        .onTapGesture { model.open(session) }
                                        .contextMenu { SessionActions(session: session) }
                                        .draggable(session.path)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            // Al pie de la barra lateral: la ubicación que **nunca** toca el historial, ni siquiera el
            // borde donde termina.
            if model.avatarPosition == .barra {
                Divider().opacity(0.4)
                CatAvatarView(state: model.catState)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }

    /// Agrupa el **historial**: solo lo que no está en un space, para que nada aparezca dos veces.
    private var groupedByProject: [(project: String, title: String, sessions: [SessionSummary])] {
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for session in model.sessionsOutsideSpaces {
            if buckets[session.project] == nil {
                order.append(session.project)
                buckets[session.project] = []
            }
            buckets[session.project]?.append(session)
        }
        return order.map { project in
            let sessions = buckets[project] ?? []
            let title = sessions.first?.cwd.map { ($0 as NSString).lastPathComponent } ?? project
            return (project, title, sessions)
        }
    }
}

/// Resultados de búsqueda sobre el contenido de las conversaciones.
///
/// Muestra el **fragmento donde coincide** (lo arma el FTS), no solo el título: buscar sirve para
/// saber *qué* decía la conversación, y eso vive en el cuerpo.
struct SearchResultsView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isSearching && model.searchHits.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Buscando…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
        } else if model.searchHits.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.info(scheme))
                Text("Sin resultados")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("\(model.searchHits.count) resultado\(model.searchHits.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    ForEach(model.searchHits, id: \.path) { hit in
                        SearchHitRow(hit: hit)
                            .onTapGesture {
                                if let session = model.session(forPath: hit.path) {
                                    model.open(session)
                                }
                            }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

struct SearchHitRow: View {
    let hit: SessionIndex.SearchHit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: roleIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(roleLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // El fragmento se parte donde coincide para resaltarlo.
            Text(highlighted)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        var result = AttributedString()
        for (index, part) in hit.parts.enumerated() {
            var fragment = AttributedString(part)
            if index.isMultiple(of: 2) == false {
                fragment.font = .system(size: 11, weight: .semibold)
                fragment.foregroundColor = .primary
            } else {
                fragment.foregroundColor = .secondary
            }
            result.append(fragment)
        }
        return result
    }

    private var roleIcon: String {
        switch hit.role {
        case "user": return "person"
        case "assistant": return "sparkles"
        case "pensamiento": return "brain"
        default: return "doc.text"
        }
    }

    private var roleLabel: String {
        switch hit.role {
        case "user": return "vos"
        case "assistant": return "pi"
        case "pensamiento": return "pensamiento"
        default: return hit.role
        }
    }
}

/// Grupos de conversaciones que parecen un tema, propuestos como space.
///
/// La etiqueta sale de los **términos del propio grupo** ("login, permiso, sesión"): sin modelo, y
/// explicable. Nada se mueve solo — la sugerencia propone, la persona decide.
struct SuggestionsSection: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.clusterSuggestions.isEmpty {
            HStack(spacing: 6) {
                CollapseChevron(sectionKey: SidebarSection.sugerencias, title: "Sugerencias")
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("SUGERENCIAS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                SectionCount(count: model.clusterSuggestions.count)
                Spacer()
                if model.isNamingClusters {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                } else {
                    // Un pedido por grupo, cacheado. Y se muestra cuántos se hicieron: el costo del
                    // modelo tiene que ser visible, no una sorpresa en la factura.
                    Button(model.namingRequests > 0
                           ? "Nombrar (\(model.namingRequests))"
                           : "Nombrar") {
                        model.nameClustersWithModel()
                    }
                    .blancoDeClic()
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .help("Le pide al modelo un nombre por grupo. Uno solo por grupo, y queda guardado: "
                          + "nunca se repite. Si falla, queda la etiqueta del grupo.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if !model.isCollapsed(SidebarSection.sugerencias) {
                ForEach(model.clusterSuggestions.prefix(4)) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .help(suggestion.modelName == nil
                              ? "Etiqueta armada con los términos del grupo, sin modelo."
                              : "Nombre puesto por el modelo. Los términos del grupo son: "
                                + suggestion.topTerms.joined(separator: ", "))
                    HStack(spacing: 6) {
                        Text(suggestion.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.info(scheme))
                        Spacer(minLength: 0)
                        Button("Crear") { model.accept(suggestion) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Button("Ignorar") { model.dismiss(suggestion) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.035))
                .cornerRadius(6)
                .padding(.horizontal, 6)
                .help("Conversaciones que comparten estos términos. Nada se mueve hasta que aceptes.")
                }
            }
        }
    }
}

/// Los spaces, con sus conversaciones adentro.
///
/// Es la mitad de arriba del sidebar: la organización propia. Abajo queda el historial con lo que no
/// está en ningún space, así que cada conversación aparece en un solo lugar y ninguna desaparece.
struct SpacesSection: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: AppModel

    /// Si los spaces están plegados enteros. El estado de cada space y de esta sección vive en el store:
    /// acá solo se lee.
    private var collapsed: Set<String> { model.collapsedSections }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CollapseChevron(sectionKey: SidebarSection.espacios, title: "Spaces")
                Text("SPACES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                SectionCount(count: model.spaces.count)
                Spacer()
                Button {
                    if let space = model.createSpace(named: "Space \(model.spaces.count + 1)") {
                        model.activeSpaceID = space.id
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .blancoDeClic()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Crear un space")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if !model.isCollapsed(SidebarSection.espacios) {
            ForEach(model.spaces) { space in
                spaceHeader(space)
                if !model.isCollapsed(SidebarSection.space(space.id)) {
                    ForEach(model.sessions(inSpace: space)) { session in
                        SessionRow(session: session,
                                   selected: session.path == model.current?.path)
                            .padding(.leading, 10)
                            .onTapGesture { model.open(session) }
                            .contextMenu { SessionActions(session: session) }
                            .draggable(session.path)
                    }
                    if model.sessions(inSpace: space).isEmpty {
                        Text("vacío · arrastrá una conversación acá")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.info(scheme))
                            .padding(.leading, 26)
                            .padding(.vertical, 2)
                    }
                }
            }
            }   // cierra el plegado de la sección de spaces entera
        }
        // Soltar una conversación sobre la lista de spaces la mete en el space que corresponda: el
        // destino real es cada encabezado, pero acá se tolera el soltado en cualquier parte.
        .dropDestination(for: String.self) { items, _ in
            guard let path = items.first,
                  let session = model.sessions.first(where: { $0.path == path }),
                  let target = model.spaces.first else { return false }
            model.move(session, toSpaceID: target.id)
            return true
        }
    }

    private func spaceHeader(_ space: Space) -> some View {
        HStack(spacing: 5) {
            CollapseChevron(sectionKey: SidebarSection.space(space.id), title: space.name)

            Circle()
                .fill(color(space.color))
                .frame(width: 7, height: 7)

            Text(space.name)
                .font(.system(size: 11.5, weight: model.activeSpaceID == space.id ? .semibold : .medium))
                .lineLimit(1)

            Text("\(space.tabs.count)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.info(scheme))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(model.activeSpaceID == space.id ? Color.accentColor.opacity(0.14) : .clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { model.activeSpaceID = space.id }
        .contextMenu {
            Button("Renombrar…") { model.renameSpace(id: space.id) }
            Menu("Color") {
                ForEach(Space.SpaceColor.allCases, id: \.self) { value in
                    Button(value.label) { model.setColor(value, forSpace: space.id) }
                }
            }
            Divider()
            Button("Borrarlo (las conversaciones no se tocan)") { model.deleteSpace(id: space.id) }
        }
        .draggable(space.id) { Text(space.name) }
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first else { return false }
            // Si lo que se soltó es un space, se reordena; si es una conversación, se mueve acá.
            if model.spaces.contains(where: { $0.id == dropped }) {
                var ids = model.spaces.map(\.id)
                guard let from = ids.firstIndex(of: dropped),
                      let to = ids.firstIndex(of: space.id), from != to else { return false }
                ids.remove(at: from)
                ids.insert(dropped, at: to)
                model.reorderSpaces(ids: ids)
                return true
            }
            guard let session = model.sessions.first(where: { $0.path == dropped }) else { return false }
            model.move(session, toSpaceID: space.id)
            return true
        }
    }

    private func color(_ value: Space.SpaceColor) -> Color {
        switch value {
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}

/// Acciones de una conversación, en el menú contextual: es donde cualquiera las busca en macOS.
struct SessionActions: View {
    let session: SessionSummary
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Abrir") { model.open(session) }
        Divider()
        if !model.spaces.isEmpty {
            Menu("Mover a space") {
                ForEach(model.spaces) { space in
                    Button(space.name) { model.move(session, toSpaceID: space.id) }
                }
                Divider()
                Button("Sacar de todos los spaces") {
                    try? model.removeFromSpaces(sessionPath: session.path)
                }
            }
        }
        Button("Renombrar…") { model.rename(session) }
        Button("Bifurcar desde un mensaje…") { model.fork(session) }
        Button("Exportar a HTML") { model.exportHTML(session) }
        Divider()
        Button("Mover a la papelera…") { model.delete(session) }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel

    let session: SessionSummary
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var accessibility: AccessibilityObserver

    /// El color de la marca: el acento para lo que está corriendo, naranja para lo que pide a la persona, y
    /// rojo para lo que falló. Los tres casos que ya distingue el panel de agentes.
    private func indicatorColor(_ estado: InstanceState) -> Color {
        switch estado {
        case .blocked: return .orange
        case .failed: return .red
        default: return .accentColor
        }
    }

    var body: some View {
        // Solo cuenta cuando se corre con `--measure-layout`: es la medición del efecto de plegar.
        let _ = LayoutProbe.noteRow(session.path)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if !session.cwdIsAvailable {
                    // Pi se niega a abrir sesiones cuya carpeta ya no existe. Mejor decirlo acá que
                    // dejar que el usuario haga clic y reciba un error.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("No se puede abrir: la carpeta «\(session.cwd ?? "?")» ya no existe.")
                }
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(session.relativeDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(session.sizeLabel)
                Text("·")
                Text(session.previewAuthor == "user" ? "vos" : "pi")
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.info(scheme))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.userBubble(scheme) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
    }
}
