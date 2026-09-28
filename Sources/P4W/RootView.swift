import SwiftUI
import P4WCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var accessibility: AccessibilityObserver
    @Environment(\.colorScheme) private var scheme
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            content
            // El velo cubre la franja de la barra superior para que lo que hace scroll por
            // debajo se desvanezca en vez de superponerse al título y a los botones.
            TopScrim()
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        // El ícono del Dock, actualizado **solo cuando el estado cambia**. Es un `onChange` y no un
        // temporizador: si el estado no cambia, no pasa nada.
        .onChange(of: model.catState) { _, _ in model.syncDockIcon() }
        .onAppear { model.syncDockIcon(force: true) }
        .background(Group {
            if accessibility.reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VibrancyBackground(material: .underWindowBackground)
            }
        })
        .animation(accessibility.reduceMotion ? nil : .easeInOut(duration: 0.22),
                   value: model.showAgentPanel)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.loadSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recargar conversaciones")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.windowTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let cwd = model.current?.cwd {
                        Text((cwd as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 420)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // **Modo simple**: el encabezado se queda con el título y nada más. Configuración de Pi, los
                // tres selectores y el panel son herramientas de quien lo configuró, no de quien conversa.
                if model.interfaceMode.showsModelControls {
                Button {
                    model.loadSettings()
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Configuración de Pi")
                ModelPicker()
                ThinkingPicker()
                ProfilePicker()
                Button {
                    model.showAgentPanel.toggle()
                } label: {
                    // Símbolos **verificados** contra el sistema: la variante sin `.filled` no existe y
                    // SwiftUI la reportaba decenas de veces por segundo, dejando el ícono vacío.
                    // El estado se distingue por color, no por un símbolo inexistente.
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                        .foregroundStyle(model.showAgentPanel ? Color.accentColor : Color.primary)
                }
                .help("Panel de agentes")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(accessibility)
        }
        .onDisappear { model.shutdown() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // ⌘⌫ para mandar a la papelera la conversación abierta. Va oculto: el atajo es el que
            // usa macOS para borrar, y el gesto destructivo pide confirmación igual.
            Group {
                Button("") { if let current = model.current { model.delete(current) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("") { if let current = model.current { model.rename(current) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                // ⌘1…9 y ⌃Tab: cambiar de conversación sin soltar el teclado. ⌘W cierra la actual,
                // que **no** la borra: vuelve a estar en el historial.
                ForEach(1...9, id: \.self) { number in
                    Button("") { model.selectTab(number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
                Button("") { model.nextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("") { model.closeCurrentTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            if let error = model.supervisorError {
                SetupBanner(message: error)
            }
            HSplitLayout
            if model.interfaceMode.showsAgentPanel && model.showAgentPanel && !model.agents.isEmpty {
                Divider().opacity(0.4)
                AgentPanelView()
                    .frame(height: 132)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var HSplitLayout: some View {
        HStack(spacing: 0) {
            SessionListView()
                .frame(minWidth: 220, idealWidth: 268, maxWidth: 340)
                // El ícono del Dock, actualizado **solo cuando el estado cambia**. Es un `onChange` y no un
        // temporizador: si el estado no cambia, no pasa nada.
        .onChange(of: model.catState) { _, _ in model.syncDockIcon() }
        .onAppear { model.syncDockIcon(force: true) }
        .background(Group {
                    if accessibility.reduceTransparency {
                        Color(nsColor: .controlBackgroundColor)
                    } else {
                        VibrancyBackground(material: .sidebar)
                    }
                })
            Divider().opacity(0.5)
            ChatView()
        }
    }
}

/// Selector de perfil de arranque. Los perfiles son configurables (§6.1), y acá se muestra
/// el costo medido de cada uno para que elegir `full` sea informado y no una sorpresa.
struct ProfilePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.profiles, id: \.name) { profile in
                Button {
                    model.changeProfile(to: profile.name)
                } label: {
                    if profile.name == model.selectedProfileName {
                        Label(profile.label, systemImage: "checkmark")
                    } else {
                        Text(profile.label)
                    }
                    Text(profile.note)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(model.selectedProfile.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }

        }
        .menuStyle(.borderlessButton)
        .blancoDeClic()
        .fixedSize()
        .help("Cómo se arranca Pi en cada conversación. Cambiarlo reinicia el proceso y conserva la conversación.\n\nPerfil de Pi: \(model.selectedProfile.name)")
    }
}

/// Selector de modelo de **esta conversación**.
///
/// Sigue el estándar de Pi: la lista sale de `get_available_models` (solo modelos con credenciales
/// usables) y el cambio se hace con `set_model`. Pi lo registra en la sesión (`model_change`), así
/// que reabrir la conversación lo restaura; el predeterminado de Pi no se toca.
///
/// **Sin submenús.** Un `Menu` anidado dentro de otro `Menu` en macOS tiene un bug conocido en el
/// que los submenús no se pueden abrir; por eso la lista es plana y el proveedor va en el texto.
/// El `.id()` fuerza a refrescar el label, que si no se queda con el valor viejo.
struct ModelPicker: View {
    @EnvironmentObject private var model: AppModel

    private var label: String {
        if model.models.isEmpty { return "elegir modelo" }
        return model.currentModel?.shortLabel ?? "modelo"
    }

    /// Agrupado por proveedor para separar visualmente, pero **sin submenús**: el proveedor es un
    /// título de sección, no un `Menu` anidado.
    private var groupedByProvider: [(provider: String, models: [ModelOption])] {
        var order: [String] = []
        var buckets: [String: [ModelOption]] = [:]
        for option in model.models {
            let provider = option.provider.isEmpty ? "—" : option.provider
            if buckets[provider] == nil {
                order.append(provider)
                buckets[provider] = []
            }
            buckets[provider]?.append(option)
        }
        return order.map { (provider: $0, models: buckets[$0] ?? []) }
    }

    var body: some View {
        Menu {
            if model.models.isEmpty {
                Text("Pi todavía no reportó modelos con credenciales usables")
            } else {
                Button("Recargar lista de modelos") { model.refreshCapabilities() }
                Divider()
                ForEach(groupedByProvider, id: \.provider) { group in
                    Text(group.provider)
                    ForEach(group.models) { option in
                        Button {
                            model.select(model: option)
                        } label: {
                            if option.key == model.currentModel?.key {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                    Divider()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("\(model.models.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // El marco del label es también el blanco de clic: sin altura mínima, los tres menús del
            // encabezado medían 14-17 puntos de alto y se erraban.
            .frame(maxWidth: 170, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .blancoDeClic()
        .fixedSize()
        .id(model.currentModel?.key ?? "sin-modelo")
        .help("Modelo de esta conversación, elegido de la lista de Pi.")
    }
}

/// Selector de nivel de thinking. Las opciones son las que Pi reporta **para el modelo activo**:
/// con un modelo sin razonamiento devuelve solo `off`, y acá se ve exactamente eso.
struct ThinkingPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            if model.thinkingLevels.isEmpty {
                Text("El modelo no reportó niveles de thinking")
            } else {
                ForEach(model.thinkingLevels, id: \.self) { level in
                    Button {
                        model.select(thinkingLevel: level)
                    } label: {
                        if level == model.currentThinkingLevel {
                            Label(level, systemImage: "checkmark")
                        } else {
                            Text(level)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                Text(model.currentThinkingLevel ?? "—")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        // **Probado, no supuesto:** con `.fixedSize()` el menú se queda con el tamaño ideal del texto y mide
        // 15 puntos de alto, aunque el marco se ponga en el label. Sacándolo y aplicando el blanco al botón
        // del menú, la accesibilidad reporta la altura real.
        .blancoDeClic()
        .id(model.currentThinkingLevel ?? "sin-nivel")
        .help("Nivel de razonamiento del modelo activo. No se inventan opciones.")
    }
}

/// Aviso cuando falta el prerrequisito. No es un onboarding: solo dice qué falta y cómo resolverlo.
struct SetupBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}
