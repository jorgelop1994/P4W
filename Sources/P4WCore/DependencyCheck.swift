import Foundation

/// Qué necesita P4W para funcionar, en **tres niveles** — porque no es lo mismo que falte lo que hace
/// andar todo que lo que solo mejora la experiencia.
///
/// - **Obligatorio**: sin esto no hay nada. Se avisa y no se puede ignorar.
/// - **Recomendado**: funciona sin esto, pero peor. Se avisa una vez y se puede descartar.
/// - **Opcional**: una capacidad extra. Se informa, nada más.
///
/// Nada de esto es un inventario de lo que hay instalado: cada ítem existe porque **P4W lo usa o lo
/// necesita Pi**, y el motivo está escrito en `fix` para que el aviso sirva de algo.
public enum DependencyLevel: String, Sendable, CaseIterable {
    case obligatorio
    case recomendado
    case opcional

    public var label: String {
        switch self {
        case .obligatorio: return "obligatorio"
        case .recomendado: return "recomendado"
        case .opcional: return "opcional"
        }
    }
}

/// Un requisito y su estado.
public struct DependencyItem: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let level: DependencyLevel
    public let present: Bool
    /// Qué se encontró (o no). Es el dato, no la conclusión.
    public let detail: String
    /// Qué hacer si falta. Puesto en términos de un comando o una acción concreta.
    public let fix: String

    public init(id: String, title: String, level: DependencyLevel, present: Bool,
                detail: String, fix: String) {
        self.id = id
        self.title = title
        self.level = level
        self.present = present
        self.detail = detail
        self.fix = fix
    }
}

/// El resultado completo.
public struct DependencyReport: Sendable, Equatable {
    public let items: [DependencyItem]

    public init(items: [DependencyItem]) { self.items = items }

    /// Lo que falta y es obligatorio: con esto la app no puede hacer nada.
    public var blocking: [DependencyItem] { items.filter { $0.level == .obligatorio && !$0.present } }
    /// Lo que falta y conviene: se avisa, se puede descartar.
    public var recommended: [DependencyItem] { items.filter { $0.level == .recomendado && !$0.present } }
    public var missingOptional: [DependencyItem] { items.filter { $0.level == .opcional && !$0.present } }
    public var present: [DependencyItem] { items.filter(\.present) }

    /// Si falta algo obligatorio. Lo que la UI mira para decidir si bloquea.
    public var isBlocked: Bool { !blocking.isEmpty }

    /// Una línea para el resumen, con lo que importa primero.
    public var summary: String {
        if let first = blocking.first { return "Falta \(first.title)" }
        if let first = recommended.first { return "Conviene instalar \(first.title)" }
        return "Todo lo necesario está"
    }
}

/// El chequeo. Lee lo que hay: no pregunta, **mira**.
public enum DependencyCheck {

    public static var defaultRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    }

    /// Corre el chequeo completo.
    ///
    /// - Parameter root: la carpeta de configuración de Pi (`~/.pi/agent`). Se pasa para poder verificar el
    ///   chequeo con carpetas fabricadas, sin depender de la máquina de nadie.
    public static func run(root: String = defaultRoot,
                           environment: ShellEnvironment = .resolve()) -> DependencyReport {
        var items: [DependencyItem] = []

        // 1. `pi`. Es lo único que P4W lanza: sin esto la app es una ventana vacía.
        let pi = environment.piExecutable?.path
        items.append(DependencyItem(
            id: "pi", title: "Pi", level: .obligatorio, present: pi != nil,
            detail: pi ?? "no está en el PATH del shell de login",
            fix: "Instalalo con `npm install -g @earendil-works/pi-coding-agent` y volvé a abrir P4W."
        ))

        // 2. `node`. Pi no arranca sin Node, así que el requisito es real aunque P4W no lo llame directo.
        let node = environment.nodeExecutable?.path
        items.append(DependencyItem(
            id: "node", title: "Node.js", level: .obligatorio, present: node != nil,
            detail: node ?? "no está en el PATH del shell de login",
            fix: "Instalá Node 22 o más nuevo (`brew install node`) y volvé a abrir P4W."
        ))

        // 3. Una carpeta de configuración de Pi, con al menos un modelo.
        let folder = FileManager.default.fileExists(atPath: root)
        let models = folder ? providerNames(root: root) : []
        items.append(DependencyItem(
            id: "modelos", title: "Al menos un modelo configurado", level: .obligatorio,
            present: !models.isEmpty,
            detail: models.isEmpty ? (folder ? "no hay proveedores en models.json" : "no existe \(root)")
                                   : "\(models.count) proveedores: \(models.prefix(4).joined(separator: ", "))",
            fix: "Configurá un proveedor con `pi` (por ejemplo `/model`), o poné tus claves en \(root)/auth.json."
        ))

        // 4. Un proveedor elegido. Sin modelo seleccionado, Pi no sabe con qué contestar.
        let selected = selectedModel(root: root)
        items.append(DependencyItem(
            id: "modelo-elegido", title: "Un modelo elegido", level: .obligatorio,
            present: selected != nil,
            detail: selected ?? "no se pudo leer el modelo por defecto",
            fix: "Elegí un modelo dentro de Pi y P4W lo va a usar: no configura proveedores, refleja los que hay."
        ))

        // 5. El navegador: **recomendado**, no obligatorio. Las búsquedas que necesitan cookies (Gemini,
        //    Kagi con sesión) van por el navegador; el resto del acceso a web no lo necesita.
        let browsers = installedBrowsers()
        items.append(DependencyItem(
            id: "navegador", title: "Un navegador", level: .recomendado, present: !browsers.isEmpty,
            detail: browsers.isEmpty ? "no encontré ninguno en /Applications"
                                     : browsers.joined(separator: ", "),
            fix: "Algunas búsquedas por web usan las cookies de tu navegador (por ejemplo con sesión de "
               + "Gemini o Kagi). Sin navegador funcionan igual las que no necesitan cuenta."
        ))

        // 6. DeepSeek: **recomendado**, y con motivo. Es el proveedor con el que está medido el consumo de
        //    P4W (122 MB y 0,25 s de arranque en el perfil liviano) y el que hace que el caché de prefijo
        //    valga la pena. No es el único que anda: es el que está probado.
        // Ojo: DeepSeek **no siempre es un proveedor aparte**. Puede venir servido por otro (acá llega a
        // través de `command-code`), así que el modelo elegido lo dice mejor que la lista de proveedores.
        // La primera versión de este chequeo miraba solo los proveedores y reportaba que faltaba DeepSeek
        // cuando el modelo en uso era `deepseek/deepseek-v4-flash`. Un reporte equivocado es peor que no
        // tener reporte.
        let deepSeekInUse = selected?.lowercased().contains("deepseek") ?? false
        let deepSeekProvider = models.contains { $0.lowercased().contains("deepseek") }
        let hasDeepSeek = deepSeekInUse || deepSeekProvider
        items.append(DependencyItem(
            id: "deepseek", title: "DeepSeek (recomendado)", level: .recomendado, present: hasDeepSeek,
            detail: hasDeepSeek
                ? (deepSeekInUse ? "en uso: \(selected ?? "")" : "hay un proveedor DeepSeek configurado")
                : "no hay un proveedor DeepSeek configurado",
            fix: "Es el proveedor con el que están medidos los perfiles y el ahorro del caché de prefijo. "
               + "Cualquier otro funciona, pero los números de este proyecto son con DeepSeek."
        ))

        // 7. El acceso a web: **opcional**. Aporta búsqueda y lectura de páginas; el chat anda sin eso.
        let webAccess = webAccessInstalled(root: root)
        items.append(DependencyItem(
            id: "acceso-web", title: "Acceso a web", level: .opcional, present: webAccess,
            detail: webAccess ? "pi-web-access instalado" : "pi-web-access no está instalado",
            fix: "Instalalo dentro de Pi para que pueda buscar en la web y leer páginas."
        ))

        return DependencyReport(items: items)
    }

    /// Los nombres de los proveedores, sin tocar las claves: se leen las claves del diccionario, nunca los
    /// valores. Un chequeo de dependencias no tiene por qué ver un secreto.
    public static func providerNames(root: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: "\(root)/models.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var names: [String] = []
        if let providers = object["providers"] as? [String: Any] { names += providers.keys }
        if let providers = object["providers"] as? [[String: Any]] {
            names += providers.compactMap { $0["id"] as? String ?? $0["name"] as? String }
        }
        return names.sorted()
    }

    /// El modelo por defecto, tal como está escrito en la configuración de Pi.
    public static func selectedModel(root: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(root)/settings.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["model", "defaultModel", "default_model"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Navegadores instalados. Safari cuenta: está en toda Mac y sirve para las búsquedas que abren páginas.
    public static func installedBrowsers() -> [String] {
        let candidates = ["Safari", "Google Chrome", "Chromium", "Firefox", "Brave Browser",
                          "Microsoft Edge", "Arc"]
        let manager = FileManager.default
        return candidates.filter { manager.fileExists(atPath: "/Applications/\($0).app") }
    }

    public static func webAccessInstalled(root: String) -> Bool {
        let path = "\(root)/npm/node_modules/pi-web-access"
        return FileManager.default.fileExists(atPath: path)
    }
}
