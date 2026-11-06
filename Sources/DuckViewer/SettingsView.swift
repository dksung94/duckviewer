import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ClaudeTab()
                .tabItem { Label("Claude", systemImage: "sparkles") }
            TemplatesTab()
                .tabItem { Label("프롬프트 템플릿", systemImage: "text.badge.star") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct ClaudeTab: View {
    @AppStorage(ClaudeSettings.modelKey) private var model = ""
    @AppStorage(ClaudeSettings.languageKey) private var language = ClaudeSettings.defaultLanguage
    @AppStorage(ClaudeSettings.allowWriteKey) private var allowWrite = false
    @State private var claudePath: String?

    var body: some View {
        Form {
            Section {
                Picker("모델", selection: $model) {
                    Text("Claude Code 기본값").tag("")
                    Text("Opus").tag("opus")
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                }
                TextField("응답 언어", text: $language, prompt: Text(ClaudeSettings.defaultLanguage))
            }
            Section {
                Toggle("Claude가 PDF 폴더에 새 파일을 만들 수 있게 허용", isOn: $allowWrite)
                Text("켜면 “요약을 파일로 저장해줘” 같은 요청을 처리할 수 있습니다. 기존 파일은 덮어쓰지 않도록 지시합니다. 끄면 PDF 읽기만 허용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("claude") {
                    Text(claudePath ?? "찾는 중…")
                        .font(.caption.monospaced())
                        .foregroundStyle(claudePath == "찾지 못함" ? .red : .secondary)
                        .textSelection(.enabled)
                }
                Text("문서마다 Claude Code 세션이 하나씩 만들어지고, PDF가 있는 폴더에서 실행됩니다. 세션은 Claude Code에도 남아서 터미널에서 `claude --resume`으로 이어갈 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { claudePath = await Self.findClaude() }
    }

    private static func findClaude() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "command -v claude"]
            process.environment = ShellEnvironment.resolved
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? "찾지 못함" : path
        }.value
    }
}

private struct TemplatesTab: View {
    @State private var templates = PromptTemplates.load()
    @State private var selection: PromptTemplate.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(templates) { template in
                        Label(template.name, systemImage: template.icon).tag(template.id)
                    }
                    .onMove { from, to in
                        templates.move(fromOffsets: from, toOffset: to)
                        PromptTemplates.save(templates)
                    }
                }
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil || templates.count <= 1)
                    Spacer()
                    Button("기본값") {
                        templates = PromptTemplates.defaults
                        PromptTemplates.save(templates)
                        selection = templates.first?.id
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)

            Divider()

            if let index = templates.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("이름", text: binding(index, \.name))
                    TextField("아이콘 (SF Symbol)", text: binding(index, \.icon))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("지시문")
                        TextEditor(text: binding(index, \.instruction))
                            .font(.body)
                            .frame(minHeight: 120)
                        Text("“아래 내용을 ” 뒤에 이어 붙습니다. {language}는 응답 언어로 바뀝니다. 앞의 3개는 선택 액션 바에, 처음 2개는 ⇧⌘1·⇧⌘2 단축키에 쓰입니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("템플릿을 고르세요")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? templates.first?.id }
    }

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<PromptTemplate, String>) -> Binding<String> {
        Binding(
            get: { templates.indices.contains(index) ? templates[index][keyPath: keyPath] : "" },
            set: { value in
                guard templates.indices.contains(index) else { return }
                templates[index][keyPath: keyPath] = value
                PromptTemplates.save(templates)
            }
        )
    }

    private func add() {
        let template = PromptTemplate(name: "새 템플릿", icon: "star", instruction: "")
        templates.append(template)
        PromptTemplates.save(templates)
        selection = template.id
    }

    private func remove() {
        templates.removeAll { $0.id == selection }
        PromptTemplates.save(templates)
        selection = templates.first?.id
    }
}
