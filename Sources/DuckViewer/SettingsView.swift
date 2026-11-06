import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            TemplatesTab()
                .tabItem { Label("프롬프트 템플릿", systemImage: "text.badge.star") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct AIPreset: Identifiable {
    let id = UUID()
    let name: String
    let command: String
    let note: String
}

private let presets: [AIPreset] = [
    AIPreset(name: "Claude Code", command: "claude -p", note: "기본값"),
    AIPreset(name: "Claude Code (Sonnet)", command: "claude -p --model sonnet", note: "빠르고 저렴"),
    AIPreset(name: "Codex CLI", command: "codex exec --skip-git-repo-check -", note: "stdin에서 프롬프트를 읽음"),
    AIPreset(name: "Gemini CLI", command: "gemini", note: "미검증, stdin 입력"),
    AIPreset(name: "Ollama 로컬 Qwen3.5 9B", command: "ollama run qwen3.5:9b", note: "미검증, 약 6.6GB, `ollama pull qwen3.5:9b` 필요"),
    AIPreset(name: "Ollama 로컬 Qwen3.5 27B", command: "ollama run qwen3.5:27b", note: "미검증, 약 17GB, 메모리 32GB 이상 권장"),
]

private struct AISettingsTab: View {
    @AppStorage(AISettings.commandKey) private var command = AISettings.defaultCommand
    @AppStorage(AISettings.languageKey) private var language = AISettings.defaultLanguage

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("AI 명령어", text: $command, prompt: Text(AISettings.defaultCommand))
                        .font(.body.monospaced())
                    Menu("프리셋") {
                        ForEach(presets) { preset in
                            Button {
                                command = preset.command
                            } label: {
                                Text(preset.name)
                                Text(preset.note.isEmpty ? preset.command : "\(preset.command) · \(preset.note)")
                            }
                        }
                    }
                    .fixedSize()
                }
                Text("""
                프롬프트는 stdin으로 전달되고, 명령어는 터미널과 같은 셸 환경(PATH 포함)에서 실행됩니다.
                치환 변수: {file} 현재 PDF 경로, {page} 현재 페이지 번호,
                {prompt_file} 프롬프트를 담은 임시 파일 경로 (stdin을 읽지 않는 CLI용, 예: mycli --input {prompt_file})
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                TextField("응답 언어", text: $language, prompt: Text(AISettings.defaultLanguage))
            }
        }
        .formStyle(.grouped)
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
