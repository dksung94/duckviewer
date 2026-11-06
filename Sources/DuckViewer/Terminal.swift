import AppKit
import SwiftTerm
import SwiftUI

/// 내장 터미널. 패널을 숨겼다 다시 열어도 셸 세션이 유지되도록 뷰를 한 번만 만든다.
@MainActor
final class TerminalController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalController()

    @Published private(set) var isAlive = false
    private var startedAt = Date.distantPast
    private var startedDirectory: URL?
    private(set) lazy var view: LocalProcessTerminalView = {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = self
        return view
    }()

    func startIfNeeded(in directory: URL?) {
        guard !isAlive else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "ko_KR.UTF-8"
        env["DUCKVIEWER_CONTEXT"] = AppPaths.context.path
        let dir = directory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        view.startProcess(
            executable: shell,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent, // 로그인 셸
            currentDirectory: dir
        )
        isAlive = true
        startedAt = Date()
        startedDirectory = directory
    }

    /// 앱이 파일과 함께 실행되면 셸이 문서보다 먼저 홈 폴더에서 뜰 수 있다.
    /// 방금 문서 없이 시작한 셸이면 PDF 폴더로 옮긴다. 사용 중인 세션은 건드리지 않는다.
    func adoptDirectoryIfFresh(_ directory: URL) {
        guard isAlive, startedDirectory == nil, Date().timeIntervalSince(startedAt) < 3 else { return }
        startedDirectory = directory
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // 앞의 공백은 셸 히스토리에 남기지 않기 위함
        view.send(txt: " cd \(quoted) && clear\n")
    }

    func restart(in directory: URL?) {
        if isAlive { view.terminate() }
        isAlive = false
        startIfNeeded(in: directory)
    }

    /// 텍스트를 입력만 하고 실행(엔터)은 하지 않는다.
    func type(_ text: String) {
        view.send(txt: text)
        view.window?.makeFirstResponder(view)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // 다시 시작할 때 이전 셸의 종료 알림이 늦게 올 수 있으므로 현재 프로세스 상태로 판단한다.
        Task { @MainActor in
            if !self.view.process.running { self.isAlive = false }
        }
    }
}

struct TerminalPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var terminal = TerminalController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("터미널").font(.caption.weight(.semibold))
                Text("$DUCKVIEWER_CONTEXT")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("현재 파일, 페이지, 선택 텍스트가 담긴 JSON 경로 (\(AppPaths.context.path))")
                Spacer(minLength: 4)
                Button { terminal.type(state.selectionText) } label: {
                    Image(systemName: "text.insert")
                }
                .disabled(!state.hasSelection)
                .help("선택 텍스트를 터미널에 입력")
                Button {
                    terminal.restart(in: state.fileURL?.deletingLastPathComponent())
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새 셸로 다시 시작")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            TerminalHost(controller: terminal)
                .onAppear {
                    // 파일과 함께 실행될 때 문서가 먼저 열리도록 잠깐 기다렸다가 셸을 띄운다.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        terminal.startIfNeeded(in: state.fileURL?.deletingLastPathComponent())
                    }
                }
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let view = controller.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
