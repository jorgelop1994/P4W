import SwiftUI
import P4WCore

/// Vista de configuración: **la de Pi, no una de P4W**.
///
/// Los controles se generan desde el esquema que se parsea de los docs de Pi (`docs/settings.md`),
/// así que si Pi agrega un ajuste, aparece acá sin tocar código. Lo que P4W no entiende (objetos
/// libres) se muestra pero no se edita, en vez de esconderse.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var sections: [(name: String, settings: [PiSettingsSchema.Setting])] {
        var order: [String] = []
        var buckets: [String: [PiSettingsSchema.Setting]] = [:]
        for setting in model.settingsSchema {
            if buckets[setting.section] == nil {
                order.append(setting.section)
                buckets[setting.section] = []
            }
            buckets[setting.section]?.append(setting)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error = model.settingsError {
                banner(error, color: .red)
            }
            if model.settingsAreLocked {
                banner("Hay \(model.activeInstanceCount) conversación(es) activa(s). Se puede mirar, pero "
                       + "no guardar: Pi lee la configuración al arrancar. Esperá a que se liberen (el "
                       + "reciclador lo hace solo).", color: .orange)
            }
            if model.settingsExternalChange {
                banner("Pi modificó este archivo mientras la ventana estaba abierta. Se va a releer antes "
                       + "de guardar, así no se pierde su cambio.", color: .blue)
            }

            if model.settingsSchema.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.info(scheme))
                    Text("No pude leer el esquema de configuración de Pi")
                        .font(.system(size: 12, weight: .medium))
                    Text("Busqué `docs/settings.md` dentro del paquete de Pi. La configuración sigue en "
                         + "`~/.pi/agent/settings.json`: podés editarla a mano.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.name) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.name)
                                    .font(.system(size: 12, weight: .semibold))
                                ForEach(section.settings) { setting in
                                    SettingRow(setting: setting)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }

            footer
        }
        .frame(width: 640, height: 560)
        .background(model.settingsAreLocked ? Color.clear : Color.clear)
        .onAppear { model.loadSettings() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Configuración de Pi")
                .font(.system(size: 14, weight: .semibold))
            Text("P4W no tiene configuración propia: esta es la de Pi, en ~/.pi/agent/settings.json. "
                 + "Lo que cambies acá se ve en `pi` de la terminal.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = model.settingsDocPath {
                Text("Controles generados desde: \((path as NSString).abbreviatingWithTildeInPath) · "
                     + "\(model.settingsSchema.count) ajustes")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.info(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = model.settingsMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Recargar") { model.loadSettings() }
            Button("Listo") { dismiss() }
                .keyboardShortcut(.defaultAction)
            Button("Guardar") {
                if let failure = model.applySettings() { model.settingsError = failure }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.settingsAreLocked || model.settingsSchema.isEmpty)
        }
        .padding(14)
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill").foregroundStyle(color).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.10))
    }
}

/// Un control por ajuste, elegido por el tipo que declara el documento de Pi.
struct SettingRow: View {
    @Environment(\.colorScheme) private var scheme
    let setting: PiSettingsSchema.Setting
    @EnvironmentObject private var model: AppModel

    private var binding: Binding<String> {
        Binding(
            get: { model.settingsValues[setting.key] ?? "" },
            set: { model.settingsValues[setting.key] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(setting.key)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 200, alignment: .leading)
                control
                Spacer(minLength: 0)
            }
            if !setting.help.isEmpty {
                Text(setting.help)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.info(scheme))
                    .lineLimit(2)
                    .padding(.leading, 210)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch setting.kind {
        case .boolean:
            Toggle("", isOn: Binding(
                get: { ["true", "1"].contains(binding.wrappedValue.lowercased()) },
                set: { binding.wrappedValue = $0 ? "true" : "false" }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

        case .enumeration(let options):
            Picker("", selection: binding) {
                Text("— sin definir").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

        case .number:
            TextField(setting.defaultValue ?? "", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

        case .textList:
            TextField("una por línea", text: binding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(maxWidth: 320)

        case .text:
            TextField(setting.defaultValue ?? "", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

        case .object:
            // Editar objetos anidados campo por campo queda para después: se avisa en vez de mentir.
            Text("objeto — se edita en el archivo")
                .font(.system(size: 11))
                .foregroundStyle(Palette.info(scheme))
        }
    }
}
