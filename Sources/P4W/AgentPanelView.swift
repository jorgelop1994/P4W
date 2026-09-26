import SwiftUI
import P4WCore

/// Panel inferior de agentes: solo las instancias de P4W, con estado, memoria propia y residente.
///
/// Se auto-oculta cuando hay una sola instancia (§7.5): una fila no necesita un panel.
struct AgentPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var accessibility: AccessibilityObserver

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agentes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(model.agents.count) viva\(model.agents.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.info(scheme))

                // Lo que te necesita, adelante y en naranja: es la razón de ser de este panel.
                if model.attentionCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 8))
                        Text("\(model.attentionCount) te necesita\(model.attentionCount == 1 ? "" : "n")")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                }

                Spacer()

                // Filtro con la forma de `pi-agent-board`: `s:blocked`, o texto libre.
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.info(scheme))
                    TextField("filtrar · s:blocked", text: $model.agentFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .frame(width: 150)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(5)

                Text(totalLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.filteredAgents, id: \.sessionKey) { agent in
                        AgentRow(agent: agent)
                            .onTapGesture {
                                // El panel y los atajos tienen que llevar al mismo lado.
                                if let session = model.session(forPath: agent.sessionKey) {
                                    model.open(session)
                                }
                            }
                    }
                    if model.filteredAgents.isEmpty {
                        Text(model.agentFilter.isEmpty ? "Sin conversaciones vivas"
                                                       : "Nada coincide con «\(model.agentFilter)»")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.info(scheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Group {
            if accessibility.reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                VibrancyBackground(material: .headerView)
            }
        })
    }

    /// Se reportan las dos cifras a propósito: `propia` es lo que se libera al reciclar,
    /// `residente` incluye páginas compartidas y por eso NO se paga por instancia (§2.2.1).
    private var totalLine: String {
        let own = model.filteredAgents.compactMap(\.footprintBytes).reduce(0, +)
        let resident = model.filteredAgents.compactMap(\.residentBytes).reduce(0, +)
        return "propia \(ProcessMetrics.megabytes(own)) · residente \(ProcessMetrics.megabytes(resident))"
    }
}

struct AgentRow: View {
    let agent: InstanceSummary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(agent.state.rawValue)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 58, alignment: .leading)
            Text(agent.profileName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text("pid \(agent.pid)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text("propia \(ProcessMetrics.megabytes(agent.footprintBytes))")
                .font(.system(size: 11))
                .frame(width: 94, alignment: .leading)
            Text("residente \(ProcessMetrics.megabytes(agent.residentBytes))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(String(format: "idle %.0fs", agent.idleSeconds))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(agent.reapable ? "reciclable" : "en uso")
                .font(.system(size: 11))
                .foregroundStyle(agent.reapable ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Una fila que te necesita se destaca; el resto es información de fondo.
        .background(agent.state == .blocked ? Color.orange.opacity(0.16)
                   : (agent.state == .working ? Palette.userBubble(scheme).opacity(0.5) : .clear))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .help(agent.state == .blocked ? "Te está esperando: hacé clic para ir" : "Ir a esta conversación")
    }

    private var color: Color {
        switch agent.state {
        case .working: return .green
        case .blocked: return .orange
        case .idle: return .secondary
        case .starting, .reaping: return .yellow
        case .failed: return .red
        case .cold: return Color.secondary.opacity(0.4)
        }
    }
}
