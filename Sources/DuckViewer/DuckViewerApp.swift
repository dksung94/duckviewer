import AppKit
import SwiftUI

@main
struct DuckViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    init() {
        // AppKit이 명령줄 인자를 "문서 열기"로 처리하면 첫 창이 뜨지 않는다. 인자는 직접 처리한다.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        // 파일과 함께 실행돼도 창이 뜨도록 WindowGroup을 쓰고, 외부 열기 요청은 기존 창이 받는다.
        WindowGroup("DuckViewer") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "pdf" { state.open(url) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1320, height: 840)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("열기…") { state.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .importExport) {
                Button("메모를 Markdown으로 내보내기…") { state.exportNotesMarkdown() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(state.notes.notes.isEmpty)
            }
            CommandMenu("메모") {
                Button("하이라이트") { state.highlightSelection() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(!state.hasSelection)
                Button("메모 추가…") { state.beginNote() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(state.document == nil)
                Divider()
                Button("메모 목록 보기") {
                    state.sidebarTab = .notes
                    state.sidebarVisibility = .all
                }
            }
            CommandMenu("Claude") {
                if let first = state.templates.first {
                    Button("\(first.name) – 현재 페이지") { state.runTemplate(at: 0, scope: .currentPage) }
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                    Button("\(first.name) – 선택 영역") { state.runTemplate(at: 0, scope: .selection) }
                        .keyboardShortcut("2", modifiers: [.command, .shift])
                        .disabled(!state.hasSelection)
                }
                Menu("현재 페이지") {
                    ForEach(state.templates) { template in
                        Button(template.name) { state.runAI(.template(template), scope: .currentPage) }
                    }
                }
                Menu("선택 영역") {
                    ForEach(state.templates) { template in
                        Button(template.name) { state.runAI(.template(template), scope: .selection) }
                    }
                }
                .disabled(!state.hasSelection)
                Divider()
                Button("중단") { state.claude.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.claude.isRunning)
                Divider()
                Button("새 대화…") { state.newConversation() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(state.messages.isEmpty && !state.hasSession)
                Button("터미널에서 이어하기 명령 복사") { state.copyResumeCommand() }
                    .disabled(state.resumeCommand == nil)
            }
            CommandGroup(before: .sidebar) {
                Button(state.showInspector ? "Claude 패널 숨기기" : "Claude 패널 보기") { state.showInspector.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("확대") { state.zoomIn() }
                    .keyboardShortcut("+")
                Button("축소") { state.zoomOut() }
                    .keyboardShortcut("-")
                Button("화면에 맞추기") { state.zoomToFit() }
                    .keyboardShortcut("0")
                Picker("읽기 테마", selection: $state.theme) {
                    ForEach(ReadingTheme.allCases) { Text($0.label).tag($0) }
                }
                Divider()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AI CLI가 stdin을 다 읽기 전에 끝나도 파이프 쓰기(SIGPIPE)로 앱이 죽지 않게 한다.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 셸 환경 읽기는 1–2초 걸리므로 미리 해 둔다.
        DispatchQueue.global(qos: .utility).async { _ = ShellEnvironment.resolved }
        // `DuckViewer path/to/file.pdf` 형태로 실행했을 때 바로 연다.
        if let path = CommandLine.arguments.dropFirst().first(where: { $0.lowercased().hasSuffix(".pdf") }) {
            AppState.shared.open(URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
