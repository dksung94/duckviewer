import Foundation

/// AI 패널의 빠른 실행 버튼. 설정에서 편집할 수 있다.
struct PromptTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// SF Symbol 이름
    var icon: String
    /// `{language}`는 응답 언어로 바뀐다.
    var instruction: String
}

enum PromptTemplates {
    static let key = "promptTemplates"

    static let defaults: [PromptTemplate] = [
        PromptTemplate(
            id: UUID(uuidString: "6E1E3C2A-0000-4000-8000-000000000001")!,
            name: "요약", icon: "text.alignleft",
            instruction: "핵심 위주로 요약해줘. 한두 문장 개요 뒤에 bullet로 핵심 포인트를 정리해."
        ),
        PromptTemplate(
            id: UUID(uuidString: "6E1E3C2A-0000-4000-8000-000000000002")!,
            name: "쉽게 설명", icon: "lightbulb",
            instruction: "처음 읽는 사람도 이해할 수 있게 쉽게 설명해줘. 어려운 용어는 풀어서 설명하고 예시를 들어."
        ),
        PromptTemplate(
            id: UUID(uuidString: "6E1E3C2A-0000-4000-8000-000000000003")!,
            name: "번역", icon: "character.book.closed",
            instruction: "{language}로 자연스럽게 번역해줘. 번역문만 출력해."
        ),
        PromptTemplate(
            id: UUID(uuidString: "6E1E3C2A-0000-4000-8000-000000000004")!,
            name: "핵심 용어", icon: "list.bullet.rectangle",
            instruction: "중요한 용어와 개념을 뽑아서 각각 한 줄로 정의해줘."
        ),
        PromptTemplate(
            id: UUID(uuidString: "6E1E3C2A-0000-4000-8000-000000000005")!,
            name: "퀴즈", icon: "questionmark.bubble",
            instruction: "이해도를 확인할 수 있는 질문 3개를 만들고, 각 질문 아래에 답과 근거 페이지를 적어줘."
        ),
    ]

    static func load() -> [PromptTemplate] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let templates = try? JSONDecoder().decode([PromptTemplate].self, from: data),
              !templates.isEmpty
        else { return defaults }
        return templates
    }

    static func save(_ templates: [PromptTemplate]) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum AIRequest: Equatable {
    case template(PromptTemplate)
    case ask(String)

    var title: String {
        switch self {
        case let .template(template): template.name
        case let .ask(question): question
        }
    }

    var icon: String {
        switch self {
        case let .template(template): template.icon
        case .ask: "bubble.left"
        }
    }
}

enum AIScope: Equatable {
    case currentPage
    case selection
    /// 1부터 시작하는 페이지 번호 (양 끝 포함)
    case pages(Int, Int)
    case chapter(String, Int, Int)

    var label: String {
        switch self {
        case .currentPage: "현재 페이지"
        case .selection: "선택 영역"
        case let .pages(from, to): from == to ? "p.\(from)" : "p.\(from)–\(to)"
        case let .chapter(title, from, to): "\(title) (p.\(from)–\(to))"
        }
    }
}

enum AISettings {
    static let commandKey = "aiCommand"
    static let languageKey = "aiLanguage"
    static let defaultCommand = "claude -p"
    static let defaultLanguage = "한국어"

    static var command: String {
        let value = UserDefaults.standard.string(forKey: commandKey) ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? defaultCommand : value
    }

    static var language: String {
        let value = UserDefaults.standard.string(forKey: languageKey) ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? defaultLanguage : value
    }
}

enum PromptBuilder {
    static func build(request: AIRequest, scopeLabel: String, title: String, body: String) -> String {
        let language = AISettings.language
        let task: String
        switch request {
        case let .template(template):
            task = "아래 내용을 " + template.instruction.replacingOccurrences(of: "{language}", with: language)
        case let .ask(question):
            task = "아래 내용을 바탕으로 다음 질문에 답해줘.\n질문: \(question)"
        }
        return """
        너는 PDF 독서를 돕는 어시스턴트다. 문서 제목: "\(title)", 범위: \(scopeLabel).
        \(task)
        - 응답 언어: \(language)
        - 내용의 근거가 되는 페이지는 (p.N) 형식으로 표시해.
        - 도구를 쓰거나 파일을 읽지 말고 아래 텍스트만 사용해.

        <document>
        \(body)
        </document>
        """
    }
}

/// 사용자의 터미널과 같은 PATH를 쓰기 위해 대화형 로그인 셸(`-ilc`)의 환경변수를 한 번 읽어 둔다.
/// Finder에서 실행한 앱은 환경변수가 거의 비어 있고, `-lc`만으로는 `.zshrc`의 PATH가 빠진다.
enum ShellEnvironment {
    static let resolved: [String: String] = load()

    private static func load() -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        base.removeValue(forKey: "CLAUDECODE")
        let marker = "__DUCKVIEWER_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: base["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '\(marker)'; /usr/bin/env -0"]
        process.environment = base
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return base }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: marker, options: .backwards)
        else { return base }
        var env: [String: String] = [:]
        for entry in text[start.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        guard env["PATH"] != nil else { return base }
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }
}

/// 사용자가 설정한 CLI 명령어를 셸 환경(`ShellEnvironment`)에서 실행하고, 프롬프트는 stdin으로 넘긴다.
/// 한 번에 하나만 실행한다. 출력은 콜백으로 누적된 전체 문자열을 넘긴다.
@MainActor
final class AIRunner: ObservableObject {
    struct Callbacks {
        var output: (String) -> Void
        var error: (String) -> Void
        /// 정상 종료면 종료 코드, 중단이면 nil
        var finish: (Int32?) -> Void
    }

    @Published private(set) var isRunning = false

    private var process: Process?
    private var callbacks: Callbacks?
    // 한글(3바이트)이 청크 경계에서 잘려도 깨지지 않도록 바이트를 모아 두고 전체를 다시 디코딩한다.
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var promptFile: URL?

    func run(command: String, prompt: String, variables: [String: String], workingDirectory: URL?, callbacks: Callbacks) {
        cancel()
        outBuffer = Data()
        errBuffer = Data()

        var resolved = command
        for (key, value) in variables {
            resolved = resolved.replacingOccurrences(of: "{\(key)}", with: shellQuote(value))
        }
        // stdin을 읽지 않는 CLI를 위해 `{prompt_file}`은 프롬프트를 담은 임시 파일 경로로 바꾼다.
        // (프롬프트를 인자로 직접 넘기면 페이지 범위가 길 때 인자 길이 제한에 걸린다)
        promptFile = nil
        if resolved.contains("{prompt_file}") {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("duckviewer-prompt-\(UUID().uuidString).txt")
            do {
                try Data(prompt.utf8).write(to: file)
            } catch {
                callbacks.error("프롬프트 파일을 쓰지 못했습니다: \(error.localizedDescription)")
                callbacks.finish(-1)
                return
            }
            promptFile = file
            resolved = resolved.replacingOccurrences(of: "{prompt_file}", with: shellQuote(file.path))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", resolved]
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.environment = ShellEnvironment.resolved

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(data, from: process) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(error: data, from: process) } }
        }
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // 핸들러를 끈 뒤 남은 출력을 마저 읽는다.
            let restOut = stdout.fileHandleForReading.readDataToEndOfFile()
            let restErr = stderr.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.receive(restOut, from: proc)
                    self.receive(error: restErr, from: proc)
                    self.finish(proc, status: status)
                }
            }
        }

        do {
            try process.run()
        } catch {
            callbacks.error("실행 실패: \(error.localizedDescription)")
            callbacks.finish(-1)
            return
        }
        self.process = process
        self.callbacks = callbacks
        isRunning = true

        // 큰 프롬프트가 파이프 버퍼를 막지 않도록 백그라운드에서 쓴다.
        // 프롬프트 파일을 쓰는 경우 stdin은 비워서 닫는다. (SIGPIPE는 앱 시작 시 무시하도록 설정)
        let data = promptFile == nil ? Data(prompt.utf8) : Data()
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        let callbacks = self.callbacks
        process.terminate()
        removePromptFile()
        self.process = nil
        self.callbacks = nil
        isRunning = false
        callbacks?.finish(nil)
    }

    private func receive(_ data: Data, from source: Process) {
        guard process === source, !data.isEmpty else { return }
        outBuffer.append(data)
        callbacks?.output(stripANSI(String(decoding: outBuffer, as: UTF8.self)))
    }

    private func receive(error data: Data, from source: Process) {
        guard process === source, !data.isEmpty else { return }
        errBuffer.append(data)
        callbacks?.error(stripANSI(String(decoding: errBuffer, as: UTF8.self)))
    }

    private func finish(_ source: Process, status: Int32) {
        guard process === source else { return }
        let callbacks = self.callbacks
        removePromptFile()
        process = nil
        self.callbacks = nil
        isRunning = false
        callbacks?.finish(status)
    }

    private func removePromptFile() {
        if let promptFile { try? FileManager.default.removeItem(at: promptFile) }
        promptFile = nil
    }

    /// `ollama run`의 진행 표시처럼 CLI가 섞어 보내는 터미널 제어문자를 지운다.
    private func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
