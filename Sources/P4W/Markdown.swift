import SwiftUI

// MARK: - Modelo de bloques

/// Un bloque de markdown ya separado.
///
/// El markdown de Apple (`AttributedString`) da formato **en línea** (negrita, código, enlaces) pero
/// no estructura de bloques. Eso era la causa de que las respuestas se vieran con los `#` y las
/// tablas en crudo. Acá se separa en bloques y cada uno se dibuja como corresponde: lo único que el
/// sistema no cubre son las tablas, y para eso está `TableBlock`.
/// Un bloque de markdown.
///
/// **Sin identidad propia, a propósito.** Antes tenía un `id` que, para las líneas divisorias,
/// devolvía un `UUID` nuevo en cada lectura: SwiftUI no podía reconocer ese bloque nunca y reconstruía
/// el subárbol entero en cada render. Los demás casos calculaban un hash del contenido en cada
/// acceso, que en textos largos también se paga. La identidad la da la **posición** en el arreglo
/// (el contenido es inmutable una vez parseado), y el parseo está cacheado.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, body: String)
    case table(header: [String], rows: [[String]], alignments: [TableAlignment])
    case quote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case rule
}

enum TableAlignment {
    case leading, center, trailing

    init(delimiter: String) {
        let trimmed = delimiter.trimmingCharacters(in: .whitespaces)
        let left = trimmed.hasPrefix(":")
        let right = trimmed.hasSuffix(":")
        switch (left, right) {
        case (true, true): self = .center
        case (false, true): self = .trailing
        default: self = .leading
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

struct MarkdownListItem {
    var text: String
    var indent: Int
    /// `nil` si no es una tarea; si lo es, si está marcada.
    var checked: Bool?
}

// MARK: - Parser

/// Parser de bloques por líneas. No pretende ser un CommonMark completo: cubre lo que aparece en
/// respuestas reales — títulos, párrafos, listas (con tareas y anidado), citas, tablas GFM, código
/// cercado, líneas divisorias — y ante la duda **prefiere mostrar el texto** antes que perderlo.
enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            if let fence = fenceMarker(trimmed) {
                let (block, next) = parseFence(lines, from: index, marker: fence)
                blocks.append(block)
                index = next
                continue
            }
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }
            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }
            if isTableRow(line), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                let (table, next) = parseTable(lines, from: index)
                blocks.append(table)
                index = next
                continue
            }
            if trimmed.hasPrefix(">") {
                let (quote, next) = parseQuote(lines, from: index)
                blocks.append(quote)
                index = next
                continue
            }
            if listMarker(trimmed) != nil {
                let (list, next) = parseList(lines, from: index)
                blocks.append(list)
                index = next
                continue
            }

            let (paragraph, next) = parseParagraph(lines, from: index)
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)) }
            index = next
        }
        return blocks
    }

    // MARK: Piezas

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func parseFence(_ lines: [String], from start: Int, marker: String) -> (MarkdownBlock, Int) {
        let opening = lines[start].trimmingCharacters(in: .whitespaces)
        let language = String(opening.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        return (.code(language: language.isEmpty ? nil : language,
                      body: body.joined(separator: "\n")), index)
    }

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    /// Línea divisoria: tres o más `-`, `*` o `_` y nada más.
    private static func isRule(_ trimmed: String) -> Bool {
        for character in ["-", "*", "_"] {
            let stripped = trimmed.replacingOccurrences(of: " ", with: "")
            if stripped.count >= 3, stripped.allSatisfy({ String($0) == character }) { return true }
        }
        return false
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = splitCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            return value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current); current = ""; continue }
            current.append(character)
        }
        cells.append(current)
        // El `|` de los extremos genera celdas vacías que no son columnas.
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTable(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        let header = splitCells(lines[start])
        let alignments = splitCells(lines[start + 1]).map(TableAlignment.init(delimiter:))
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, isTableRow(lines[index]) {
            let row = splitCells(lines[index])
            if !row.isEmpty, !isTableDelimiter(lines[index]) { rows.append(row) }
            index += 1
        }
        return (.table(header: header, rows: rows, alignments: alignments), index)
    }

    private static func parseQuote(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var content: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            content.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return (.quote(parse(content.joined(separator: "\n"))), index)
    }

    /// Lo que se reconoce al principio de una línea de lista.
    struct ListMarker {
        var indent: Int
        var ordered: Bool
        var text: String
        var checked: Bool?
    }

    private static func listMarker(_ trimmed: String) -> ListMarker? {
        var indent = 0
        for character in trimmed {
            if character == " " { indent += 1 } else { break }
        }
        let rest = String(trimmed.dropFirst(indent))

        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            var text = String(rest.dropFirst(bullet.count))
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
            return ListMarker(indent: indent, ordered: false, text: text, checked: checked)
        }

        // Ordenada: `1.` o `1)` seguido de espacio.
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                let offset = digits.count + 2
                return ListMarker(indent: indent, ordered: true,
                                  text: String(rest.dropFirst(offset)), checked: nil)
            }
        }
        return nil
    }

    private static func parseList(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        let ordered = listMarker(lines[start].trimmingCharacters(in: .whitespaces))?.ordered ?? false
        var items: [MarkdownListItem] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let marker = listMarker(trimmed), marker.ordered == ordered else { break }
            items.append(MarkdownListItem(text: marker.text, indent: marker.indent, checked: marker.checked))
            index += 1
        }
        return (.list(ordered: ordered, items: items), index)
    }

    private static func parseParagraph(_ lines: [String], from start: Int) -> (String, Int) {
        var content: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if fenceMarker(trimmed) != nil || parseHeading(trimmed) != nil || isRule(trimmed) { break }
            if trimmed.hasPrefix(">") || listMarker(trimmed) != nil { break }
            if isTableRow(lines[index]) { break }
            content.append(lines[index])
            index += 1
        }
        return (content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), index)
    }
}

// MARK: - Vistas

/// Renderiza markdown como bloques. Mientras el mensaje llega, el último bloque (el que todavía
/// está creciendo) se dibuja de forma económica: así no se rearma un árbol de vistas completo por
/// cada tick del revelado, y no se ven tablas a medio formar.
struct MarkdownView: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        let blocks = MarkdownCache.parsedBlocks(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if isStreaming, index == blocks.count - 1, !isComplete(block) {
                    InlineText(text: rawText(block))
                } else {
                    MarkdownBlockView(block: block)
                }
            }
        }
    }

    /// Un bloque está completo si no puede seguir creciendo.
    private func isComplete(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .code, .table, .rule: return true
        default: return false
        }
    }

    private func rawText(_ block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let value), .heading(_, let value): return value
        case .list(_, let items): return items.map(\.text).joined(separator: "\n")
        case .quote(let inner): return inner.map { rawText($0) }.joined(separator: "\n")
        default: return ""
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text: text, font: headingFont(level), weight: level <= 3 ? .semibold : .medium)
                .padding(.top, level <= 2 ? 4 : 1)

        case .paragraph(let text):
            InlineText(text: text)

        case .code(let language, let body):
            CodeBlock(language: language, code: body)

        case .table(let header, let rows, let alignments):
            TableBlock(header: header, rows: rows, alignments: alignments)

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MarkdownBlockView(block: inner)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 7) {
                        marker(for: item, ordered: ordered, index: index)
                        InlineText(text: item.text)
                            .strikethrough(item.checked == true, color: .secondary)
                            .foregroundStyle(item.checked == true ? Color.secondary : Color.primary)
                    }
                    .padding(.leading, CGFloat(item.indent) * 7)
                }
            }

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, ordered: Bool, index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .frame(width: 14, alignment: .trailing)
        } else if ordered {
            Text("\(index + 1).")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text("•")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 17, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        case 4: return .system(size: 13.5, weight: .semibold)
        case 5: return .system(size: 13, weight: .medium)
        default: return .system(size: 12.5, weight: .medium)
        }
    }
}

/// Texto con markdown **en línea**: negrita, itálica, código, enlaces. Conserva los espacios.
struct InlineText: View {
    let text: String
    var font: Font = .system(size: 13)
    var weight: Font.Weight?

    var body: some View {
        Text(MarkdownCache.inlineText(text))
            .font(font)
            .fontWeight(weight)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// El texto en línea sale de la caché: convertir markdown a `AttributedString` dentro de `body`
    /// es caro y se pagaba en cada cuadro del desplazamiento. Si el parseo falla se muestra el texto
    /// tal cual: nunca se pierde contenido por un asterisco.
}

/// Tabla GFM. Es lo único que el markdown del sistema no cubre, así que se arma a mano.
/// Con `Grid` las columnas se alinean solas al contenido, y un scroll horizontal evita que una
/// tabla ancha rompa el ancho de la conversación.
struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]
    @Environment(\.colorScheme) private var scheme

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: columnCount > 3) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(text(at: column, in: header), isHeader: true, column: column)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            cell(text(at: column, in: row), isHeader: false, column: column)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func text(at column: Int, in row: [String]) -> String {
        column < row.count ? row[column] : ""
    }

    private func alignment(_ column: Int) -> TableAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    private func cell(_ value: String, isHeader: Bool, column: Int) -> some View {
        InlineText(text: value,
                   font: .system(size: isHeader ? 11.5 : 12, weight: isHeader ? .semibold : nil))
            .frame(minWidth: 92, alignment: alignment(column).frameAlignment)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isHeader ? Color.primary.opacity(0.07) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
    }
}

struct CodeBlock: View {
    let language: String?
    /// Se llama `code` y no `body` para no chocar con la propiedad `body` de `View`.
    let code: String
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language ?? "código")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(Palette.codeBackground(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(6)
    }
}

/// Texto que se revela progresivamente mientras llega el stream.
///
/// Motivo medido (§7.1): la granularidad de los deltas **depende del proveedor**. Con
/// `deepseek-v4-flash` el texto llegó en **un solo** `text_delta`, así que sin animación local la
/// respuesta aparecería de golpe y se perdería la sensación de "está escribiendo".
///
/// **El conteo revelado NO vive acá.** Un `LazyVStack` solo mantiene vivos los views visibles: al
/// salir de pantalla y volver, el `@State` se pierde y el texto se reiniciaba o quedaba cortado.
/// El progreso lo lleva el modelo (`RevealAnimator`) y esta vista es una función pura de él.
struct StreamingText: View {
    let text: String
    let isStreaming: Bool
    /// Cuántos caracteres mostrar. Lo decide el modelo, no la vista.
    let revealed: Int

    private var visible: String {
        guard isStreaming, revealed < text.count else { return text }
        return String(text.prefix(max(0, min(revealed, text.count))))
    }

    var body: some View {
        MarkdownView(text: visible, isStreaming: isStreaming)
    }
}
