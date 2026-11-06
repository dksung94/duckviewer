import SwiftUI

struct SettingsView: View {
    @AppStorage(AISettings.commandKey) private var command = AISettings.defaultCommand
    @AppStorage(AISettings.languageKey) private var language = AISettings.defaultLanguage

    var body: some View {
        Form {
            Section {
                TextField("AI 명령어", text: $command, prompt: Text(AISettings.defaultCommand))
                    .font(.body.monospaced())
                Text("""
                프롬프트는 stdin으로 전달되고, 명령어는 터미널과 같은 셸 환경(PATH 포함)에서 실행됩니다.
                예: claude -p · codex exec - · gemini -p · ollama run llama3
                치환 변수: {file} 현재 PDF 경로, {page} 현재 페이지 번호
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                TextField("응답 언어", text: $language, prompt: Text(AISettings.defaultLanguage))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
