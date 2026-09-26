import Foundation

/// Firma temática de un texto: de qué trata, sin usar ningún modelo.
///
/// Es la capa 1 de la agrupación inteligente (§7.9 del plan). La decisión de fondo: **agrupar tiene que
/// ser local, barato y determinista**; el modelo, si participa, solo pone nombres (capa 2). Agrupar con
/// un LLM es caro y **no determinista** — el mismo conjunto da grupos distintos en cada corrida.
///
/// Todo acá es una **función pura**: mismo texto, mismo resultado, siempre. Así se puede verificar.
public enum TextSignature {

    /// Palabras que no dicen nada del tema. Español e inglés, porque el corpus real está mezclado.
    public static let stopwords: Set<String> = [
        // Español
        "de", "la", "que", "el", "en", "y", "a", "los", "del", "se", "las", "por", "un", "para",
        "con", "una", "su", "al", "es", "lo", "como", "mas", "pero", "sus", "le", "ya", "o", "este",
        "si", "porque", "esta", "entre", "cuando", "muy", "sin", "sobre", "tambien", "me", "hasta",
        "hay", "donde", "quien", "desde", "todo", "nos", "durante", "todos", "uno", "les", "ni",
        "contra", "otros", "ese", "eso", "ante", "ellos", "e", "esto", "mi", "antes", "algunos",
        "que", "unos", "yo", "otro", "otras", "otra", "el", "tanto", "esa", "estos", "mucho", "quienes",
        "nada", "muchos", "cual", "poco", "ella", "estar", "estas", "algunas", "algo", "nosotros",
        "mis", "tu", "te", "ti", "tus", "ellas", "nosotras", "vosotros", "vosotras", "os", "mio",
        "mia", "mios", "mias", "tuyo", "tuya", "tuyos", "tuyas", "suyo", "suya", "suyos", "suyas",
        "nuestro", "nuestra", "nuestros", "nuestras", "vuestro", "vuestra", "vuestros", "vuestras",
        "esos", "esas", "estoy", "estas", "esta", "estamos", "estais", "estan", "fue", "ser", "son",
        "era", "eran", "soy", "eres", "sea", "sean", "he", "has", "ha", "hemos", "han", "haya",
        "puede", "pueden", "puedo", "podemos", "hacer", "hace", "hacen", "tiene", "tienen", "tengo",
        "tenemos", "voy", "vas", "va", "vamos", "van", "ver", "visto", "decir", "dice", "digo",
        "bueno", "buena", "bien", "mal", "aqui", "ahi", "alla", "ahora", "luego", "despues", "siempre",
        "nunca", "solo", "sólo", "cada", "otra", "vez", "dos", "tres", "parte", "cosa", "cosas",
        "favor", "gracias", "hola", "gracias", "necesito", "quiero", "puedes", "puede", "ayuda",
        "tema", "caso", "forma", "manera", "ejemplo", "vez", "veces", "tipo", "algo", "alguien",
        // Inglés
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on",
        "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we",
        "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there", "their",
        "what", "so", "up", "out", "if", "about", "who", "get", "which", "go", "me", "when", "make",
        "can", "like", "time", "no", "just", "him", "know", "take", "people", "into", "year", "your",
        "good", "some", "could", "them", "see", "other", "than", "then", "now", "look", "only",
        "come", "its", "over", "think", "also", "back", "after", "use", "two", "how", "our", "work",
        "first", "well", "way", "even", "new", "want", "because", "any", "these", "give", "day",
        "most", "us", "is", "are", "was", "were", "been", "has", "had", "did", "does", "should",
        "would", "could", "please", "need", "let", "make", "made", "using", "used", "here", "where",
    ]

    /// Convierte texto libre en términos comparables: minúsculas, sin acentos, sin puntuación, sin
    /// palabras vacías y sin términos de una o dos letras.
    ///
    /// Se normalizan también los plurales simples en español (`-es`, `-s`) para que "conversaciones" y
    /// "conversación" cuenten como el mismo término. No es un lematizador: es lo mínimo que mejora la
    /// agrupación sin inventar lingüística.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "es"))
        var result: [String] = []
        var current = ""

        func flush() {
            defer { current = "" }
            guard current.count > 2 else { return }
            guard !stopwords.contains(current) else { return }
            guard current.contains(where: { $0.isLetter }) else { return }
            guard !current.allSatisfy({ $0.isNumber }) else { return }
            // Se descarta lo que es en realidad un identificador o un pedazo de fecha: nombres de archivo
            // y rutas los traen pegados (`30t17`, `019fb18a`, `11t19`), y terminaban como etiqueta de un
            // grupo. Verificado sobre el historial real: aparecían en las etiquetas.
            guard !looksLikeIdentifier(current) else { return }
            result.append(singular(current))
        }

        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// ¿Parece un identificador en vez de una palabra? Los dígitos tienen que ser una parte chica del
    /// término: una o dos cifras pegadas a una palabra real es común ("sha256"), pero cuatro o más ya
    /// sugiere un identificador, una fecha o un hash.
    static func looksLikeIdentifier(_ word: String) -> Bool {
        let digits = word.filter { $0.isNumber }.count
        guard digits > 0 else { return false }
        if digits >= 4 { return true }
        // `019fb18a` y similares: muchas letras y números alternados sin vocales suficientes.
        let vowels = word.filter { "aeiou".contains($0) }.count
        if digits >= 2 && vowels == 0 { return true }
        return double(digits) / double(word.count) > 0.4
    }

    private static func double(_ value: Int) -> Double { Double(value) }

    /// Plural simple → singular. Conservador a propósito: solo toca terminaciones claras.
    private static func singular(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("es"), word.count > 5 { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// El texto del que sale la firma de una conversación: lo que **describe** de qué trata.
    ///
    /// Se usan el nombre de la sesión, el primer mensaje de la persona y las rutas o archivos
    /// mencionados. Deliberadamente **no** se usa la conversación completa: los términos que se repiten a
    /// lo largo de miles de mensajes describen la herramienta, no el tema.
    public static func documentText(name: String?, firstUserMessage: String?, paths: [String]) -> String {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        if let firstUserMessage, !firstUserMessage.isEmpty {
            parts.append(String(firstUserMessage.prefix(600)))
        }
        // Las rutas se aportan como palabras separadas: `Code/P4W/SpacesStore.swift` aporta
        // "code", "p4w", "spacesstore", "swift".
        if !paths.isEmpty { parts.append(paths.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }

    /// Firma cruda: cuántas veces aparece cada término.
    public static func termCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens(text) { counts[token, default: 0] += 1 }
        return counts
    }
}
