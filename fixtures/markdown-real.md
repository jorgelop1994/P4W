## Cuadro resumen — Herdr 0.9.1

### Identidad

| Campo | Dato |
|---|---|
| Qué es | Runtime de terminal para agentes de código (no un tmux mejorado) |
| Tesis | Los multiplexers persisten terminales; Herdr persiste agentes |
| Versión | 0.9.1 · protocolo 22 · Rust · Apache-2.0 |
| Tracción | 40.652 ★ · 3.109 forks · 1.046.795 instalas · 1.324 plugins |
| Licencia | Apache-2.0 (cambiada desde AGPL) |

### Capacidades

| Área | Qué tiene |
|---|---|
| Jerarquía | workspace → tab → pane · IDs estables que no se reutilizan |
| Agentes | 24 kinds detectables · 18 integraciones oficiales · 5 estados |
| Control | CLI completo por grupos + socket API JSON-RPC + 25 tipos de evento |
| Persistencia | 4 niveles: detach → snapshot → resume nativo → handoff |

### Riesgos, por orden de impacto real

| # | Riesgo | Acción sugerida |
|---|---|---|
| 1 | CPU alto en macOS | Medir con ps/top sobre el server |
| 2 | Updates matan los panes | Planificar antes de brew upgrade |
| 3 | Badges poco fiables | No confiar sin verificar |

### Veredicto

> Herdr no compite en "multiplexar terminales" — eso es el medio. Compite en ser el runtime de
> orquestación de agentes: detectar cuál te necesita (`blocked`), esperarlo sin polling y darle a
> cada uno su worktree aislado.

En una línea: `herdr agent wait --until blocked` en vez de hacer polling.
