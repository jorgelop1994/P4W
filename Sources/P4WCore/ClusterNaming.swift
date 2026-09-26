import Foundation

/// Nombres para los grupos, **puestos por el modelo**.
///
/// Es la capa 2 de la agrupación (§7.9 del plan), y el reparto de trabajo es deliberado: **agrupar es
/// local y determinista (capa 1); nombrar es lo único que se le pide al modelo**. Agrupar con un LLM sería
/// caro y no reproducible.
///
/// Acá está la parte pura —armar el pedido y limpiar la respuesta—, que es la que puede fallar de formas
/// raras: un modelo contesta con comillas, con markdown, con una explicación, o con tres párrafos.
public enum ClusterNaming {

    /// El pedido: corto, en español, y con lo mínimo para decidir.
    ///
    /// Se le pasan los términos del grupo y **un par de títulos** de conversaciones. No se le pasa el
    /// contenido: para poner un nombre de tres palabras no hace falta, y cada token se paga.
    public static func prompt(terms: [String], titles: [String]) -> String {
        let termList = terms.prefix(6).joined(separator: ", ")
        let titleList = titles.prefix(3).map { "- \($0)" }.joined(separator: "\n")
        return """
        Poné un nombre corto a un grupo de conversaciones. Respondé **solo el nombre**, \
        de 2 a 4 palabras, en español, sin comillas y sin puntuación final.

        Términos que comparten: \(termList)
        \(titleList.isEmpty ? "" : "Algunas conversaciones:\n\(titleList)")
        """
    }

    /// ¿Es una línea que anuncia el nombre en vez de serlo?
    static func isPreamble(_ line: String) -> Bool {
        if line.hasSuffix(":") { return true }
        let lowered = line.lowercased()
        for start in ["claro", "por supuesto", "acá va", "aquí está", "el nombre", "nombre ",
                      "te propongo", "podría ser", "una opción"] where lowered.hasPrefix(start) {
            return true
        }
        return false
    }

    /// Limpia lo que devolvió el modelo. Devuelve `nil` si no hay nada usable: en ese caso se conserva la
    /// etiqueta heurística, que siempre está.
    ///
    /// Los modelos, cuando se les pide un nombre, entregan: comillas, markdown, un encabezado, o una frase
    /// entera explicando por qué ese nombre. Todo eso se descarta en vez de mostrarse.
    public static func clean(_ response: String) -> String? {
        let lines = response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Un modelo contesta muy seguido "Claro, acá va un nombre:" y **el nombre en la línea
        // siguiente**. Quedarse con la primera línea daría "Claro, acá va un nombre", que no es un
        // nombre. Si la primera línea es un preámbulo, el nombre está abajo.
        var candidate = lines.first ?? ""
        if isPreamble(candidate), lines.count > 1 { candidate = lines[1] }

        candidate = TerminalText.clean(candidate)              // colores, si vinieran
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#-–—:. "))

        // "El nombre es: X" y variantes.
        for prefix in ["El nombre es:", "Nombre:", "Nombre propuesto:", "Nuevo nombre:", "Name:"] {
            if candidate.lowercased().hasPrefix(prefix.lowercased()) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*: "))
            }
        }

        // Ni vacío, ni una explicación, ni algo larguísimo.
        guard !candidate.isEmpty, candidate.count <= 60 else { return nil }
        let words = candidate.split(separator: " ")
        guard (1...5).contains(words.count) else { return nil }
        // Si parece una frase en vez de un nombre, no sirve.
        guard !candidate.contains(".") || candidate.count <= 40 else { return nil }
        // Y nada de markdown de bloque: si quedaron asteriscos o almohadillas, no es un nombre.
        guard !candidate.contains("**") && !candidate.contains("##") else { return nil }

        return candidate
    }
}
