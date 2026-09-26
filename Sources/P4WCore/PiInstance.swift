import Foundation

public enum PiInstanceError: Error, CustomStringConvertible {
    case executableMissing(String)
    case launchFailed(String)
    case notRunning
    case encodingFailed(String)

    public var description: String {
        switch self {
        case .executableMissing(let detail): return "No se encontró el ejecutable de Pi: \(detail)"
        case .launchFailed(let detail): return "No se pudo lanzar Pi: \(detail)"
        case .notRunning: return "La instancia de Pi no está corriendo"
        case .encodingFailed(let detail): return "No se pudo codificar el comando: \(detail)"
        }
    }
}

/// Un proceso `pi --mode rpc` vivo.
///
/// Reglas que implementa y que no son negociables (§3 y §4 del plan):
/// - **stdin se mantiene abierto**: Pi se apaga solo cuando stdin llega a EOF, y ese EOF
///   es justamente la señal de shutdown ordenado.
/// - **stdout se lee siempre**: Pi respeta backpressure, pero un cliente que deja de leer
///   estanca el proceso. stdout es solo protocolo; los diagnósticos van por stderr.
/// - **Framing estricto en LF** vía `JSONLAccumulator`.
public final class PiInstance: @unchecked Sendable {

    public typealias EventHandler = (RPCRecord) -> Void

    public let executable: URL
    private let environment: ShellEnvironment
    private let process = Process()

    private var stdinHandle: FileHandle?
    private var outputAccumulator = JSONLAccumulator()
    private let stateLock = NSLock()
    private var isRunning = false

    /// Se invoca en una cola interna, nunca en el hilo principal.
    public var onRecord: EventHandler?
    /// Líneas de stderr. Diagnóstico, nunca protocolo.
    public var onStderr: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public var pid: pid_t { process.processIdentifier }

    /// Últimas líneas de stderr. **No son protocolo**, pero son la única explicación cuando Pi se
    /// niega a arrancar: por ejemplo "Stored session working directory does not exist: /root".
    /// Descartarlas convertía un error clarísimo en un timeout de 30 segundos.
    public private(set) var recentStderr: [String] = []
    /// Código de salida, si el proceso ya terminó.
    public private(set) var exitStatus: Int32?

    public var lastStderrLine: String? { recentStderr.last }

    /// El motivo, legible. Pi escribe varias líneas y la **última** suele ser un dato de contexto,
    /// no el error: "Stored session working directory does not exist" viene primero y
    /// "Current working directory: …" al final. Quedarse con la última daba un mensaje inútil.
    public var stderrSummary: String? {
        let tail = recentStderr.suffix(3)
        guard !tail.isEmpty else { return nil }
        return tail.joined(separator: " · ")
    }

    public init(executable: URL, environment: ShellEnvironment) {
        self.executable = executable
        self.environment = environment
    }

    /// Argumentos que hacen falta siempre: modo RPC. El perfil aporta el resto.
    public static let rpcMode: [String] = ["--mode", "rpc"]

    /// Argumentos del perfil "lean" (§6.2 del plan): sin extensiones, skills ni plantillas.
    /// Es la diferencia medida entre ~120 MB y ~360 MB de RSS, y entre 0.25 s y 5.4 s.
    public static let leanProfile: [String] = [
        "--mode", "rpc",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
    ]

    public func start(arguments: [String], workingDirectory: URL? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PiInstanceError.executableMissing(executable.path)
        }

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.childEnvironment()
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self?.rememberStderr(text)
            self?.onStderr?(text)
        }

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.stateLock.lock()
            self.isRunning = false
            self.exitStatus = finished.terminationStatus
            self.stateLock.unlock()
            self.onExit?(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw PiInstanceError.launchFailed(error.localizedDescription)
        }

        stdinHandle = stdinPipe.fileHandleForWriting
        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    private func rememberStderr(_ text: String) {
        stateLock.lock()
        for line in text.split(separator: "\n") where !line.isEmpty {
            recentStderr.append(String(line))
        }
        if recentStderr.count > 20 { recentStderr.removeFirst(recentStderr.count - 20) }
        stateLock.unlock()
    }

    private func ingest(_ data: Data) {
        let records: [Data]
        stateLock.lock()
        records = outputAccumulator.append(data)
        stateLock.unlock()
        for raw in records {
            onRecord?(RPCRecord.decode(raw))
        }
    }

    public func send(_ data: Data) throws {
        stateLock.lock()
        let handle = stdinHandle
        let running = isRunning
        stateLock.unlock()
        guard running, let handle else { throw PiInstanceError.notRunning }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw PiInstanceError.launchFailed("escritura a stdin falló: \(error.localizedDescription)")
        }
    }

    public func send(id: String?, type: String, fields: [String: Any] = [:]) throws {
        do {
            try send(RPCCommand.encode(id: id, type: type, fields: fields))
        } catch {
            throw PiInstanceError.encodingFailed("\(error)")
        }
    }

    /// Shutdown ordenado: cerrar stdin y esperar. `terminate()` solo como último recurso.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 8) -> Int32? {
        stateLock.lock()
        let handle = stdinHandle
        stdinHandle = nil
        stateLock.unlock()

        try? handle?.close()
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let pipe = process.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(300_000)
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    public var running: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }
}

// Las métricas de proceso viven en ManagedInstance.swift, sobre libproc (`P4WProc`):
// footprint real y árbol de descendientes. La versión anterior de este archivo usaba `ps`
// como aproximación, y se eliminó para que no haya dos formas de medir lo mismo.
