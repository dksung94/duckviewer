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
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "pdf" { state.open(url) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("열기…") { state.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("AI") {
                Button("현재 페이지 요약") { state.runAI(.summarize, scope: .currentPage) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("선택 영역 요약") { state.runAI(.summarize, scope: .selection) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Divider()
                Button("AI 중단") { state.ai.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("보기") {
                Button(state.showTerminal ? "터미널 숨기기" : "터미널 보기") { state.showTerminal.toggle() }
                    .keyboardShortcut("`", modifiers: .control)
                Button(state.showSidePanel ? "사이드 패널 숨기기" : "사이드 패널 보기") { state.showSidePanel.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
