import Foundation

enum AIAction: Equatable {
    case summarize
    case explain
    case translate
    case ask(String)

    var label: String {
        switch self {
        case .summarize: "요약"
        case .explain: "설명"
        case .translate: "번역"
        case .ask: "질문"
        }
    }
}

enum AIScope: Equatable {
    case currentPage
    case selection
    /// 1부터 시작하는 페이지 번호 (양 끝 포함)
    case pages(Int, Int)

    var label: String {
        switch self {
        case .currentPage: "현재 페이지"
        case .selection: "선택 영역"
        case let .pages(from, to): "p.\(from)–\(to)"
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
    static func build(action: AIAction, scope: AIScope, title: String, body: String) -> String {
        let task: String
        switch action {
        case .summarize:
            task = "아래 내용을 핵심 위주로 요약해줘. 짧은 개요 한두 문장 뒤에 bullet로 핵심 포인트를 정리해."
        case .explain:
            task = "아래 내용을 처음 읽는 사람도 이해할 수 있게 쉽게 설명해줘. 어려운 용어는 풀어서 설명해."
        case .translate:
            task = "아래 내용을 \(AISettings.language)로 자연스럽게 번역해줘. 번역문만 출력해."
        case let .ask(question):
            task = "아래 내용을 바탕으로 다음 질문에 답해줘.\n질문: \(question)"
        }
        return """
        너는 PDF 독서를 돕는 어시스턴트다. 문서 제목: "\(title)", 범위: \(scope.label).
        \(task)
        - 응답 언어: \(AISettings.language)
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
@MainActor
final class AIRunner: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var errorOutput = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastLabel = ""
    @Published private(set) var exitStatus: Int32?

    private var process: Process?

    func run(command: String, prompt: String, label: String, variables: [String: String], workingDirectory: URL?) {
        cancel()
        output = ""
        errorOutput = ""
        exitStatus = nil
        lastLabel = label

        var resolved = command
        for (key, value) in variables {
            resolved = resolved.replacingOccurrences(of: "{\(key)}", with: shellQuote(value))
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

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.output += text }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.errorOutput += text }
        }
        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // 핸들러를 끈 뒤 남은 출력을 마저 읽는다.
            let restOut = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let restErr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.output += restOut
                self.errorOutput += restErr
                self.exitStatus = status
                self.isRunning = false
                self.process = nil
            }
        }

        do {
            try process.run()
        } catch {
            errorOutput = "실행 실패: \(error.localizedDescription)"
            return
        }
        self.process = process
        isRunning = true

        // 큰 프롬프트가 파이프 버퍼를 막지 않도록 백그라운드에서 쓴다.
        let data = Data(prompt.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        isRunning = false
        errorOutput += "\n(중단됨)"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
