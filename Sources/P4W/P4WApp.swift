import P4WCore
import SwiftUI

/// Punto de entrada propio para poder ofrecer un modo de autodiagnóstico sin ventana.
/// `P4W --self-check` verifica la capa de datos y termina; sin argumentos, abre la app.
/// `P4W --logs [minutos]` vuelca los registros de la app a la terminal (para diagnosticar sin abrir nada).
@main
enum P4WMain {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.run()
        }
        if CommandLine.arguments.contains("--render-docs") {
            for line in IconRenderer.writeDocumentationImages() { print("  " + line) }
            exit(0)
        }
        if CommandLine.arguments.contains("--render-cat") {
            SelfCheck.renderCat()
        }
        if let minutos = SelfCheck.logMinutes(from: CommandLine.arguments) {
            SelfCheck.printLogs(minutes: minutos)
        }
        if CommandLine.arguments.contains("--check-updates") {
            SelfCheck.printUpdates()
        }
        if CommandLine.arguments.contains("--check-deps") {
            SelfCheck.printDependencies()
        }
        if CommandLine.arguments.contains("--render-icon") {
            for line in IconRenderer.writeIconSet(into: "dist/icon") { print(line) }
            exit(0)
        }
        if CommandLine.arguments.contains("--measure-layout") {
            // Mide, imprime y sale: sin pantalla visible, es la única forma de verificar el layout.
            LayoutProbe.enabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
                // Se lee la preferencia del disco, no del modelo: así se contrasta **lo guardado** contra
                // **lo medido**, que es la comparación que hace visible el cacheo del label.
                LayoutProbe.finish(avatarSize: CatSize.from(
                    (try? PreferencesStore())?.string(.avatarSize)))
                exit(0)
            }
        }
        P4WApp.main()
    }
}

struct P4WApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var accessibility = AccessibilityObserver()
    @StateObject private var windowVisibility = WindowVisibilityObserver()

    var body: some Scene {
        WindowGroup("P4W") {
            RootView()
                .environmentObject(model)
                .environmentObject(accessibility)
                .environmentObject(windowVisibility)
                .background(WindowConfigurator())
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            // En el menú de la app, que es donde macOS lo pone en todas las aplicaciones. Y responde
            // **siempre algo**: al día, hay una nueva, o no se pudo consultar.
            CommandGroup(after: .appInfo) {
                Button("Buscar actualizaciones…") { model.checkForUpdates(force: true) }
                    .disabled(model.isCheckingUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nueva conversación") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Mostrar panel de agentes") { model.showAgentPanel.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
    }
}
