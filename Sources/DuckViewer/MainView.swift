import SwiftUI
import UniformTypeIdentifiers

/// 왼쪽 사이드바 | 가운데 PDF | 오른쪽 Claude 대화
struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            ReaderArea()
                .inspector(isPresented: $state.showInspector) {
                    AIPanel()
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 720)
                }
        }
        .navigationTitle(state.title)
        .navigationSubtitle(state.document == nil ? "" : "\(state.currentPageIndex + 1) / \(state.pageCount)쪽")
        .searchable(text: $state.searchQuery, placement: .toolbar, prompt: "문서에서 검색")
        .onSubmit(of: .search) { state.search() }
        .onChange(of: state.searchQuery) { _, query in
            if query.isEmpty { state.clearSearch() }
        }
        .toolbar { toolbar }
        .sheet(item: $state.noteDraft) { draft in
            NoteDraftSheet(draft: draft)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in AppState.shared.open(url) }
            }
            return true
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if state.document != nil { PageNavigator() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { state.zoomOut() } label: { Label("축소", systemImage: "minus.magnifyingglass") }
                Button { state.zoomIn() } label: { Label("확대", systemImage: "plus.magnifyingglass") }
            }
            .disabled(state.document == nil)
            .help("축소 / 확대")

            Menu {
                Button("화면에 맞추기") { state.zoomToFit() }
                Section("페이지 배치") {
                    Picker("페이지 배치", selection: $state.pageLayout) {
                        ForEach(PageLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("읽기 테마") {
                    Picker("읽기 테마", selection: $state.theme) {
                        ForEach(ReadingTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                Label("보기", systemImage: "doc.text.magnifyingglass")
            }
            .help("페이지 배치와 읽기 테마")

            Toggle(isOn: $state.showInspector) {
                Label("Claude", systemImage: "sparkles")
            }
            .help("Claude 패널 (⌥⌘0)")
        }
    }
}

private struct PageNavigator: View {
    @EnvironmentObject private var state: AppState
    @State private var input = ""

    var body: some View {
        HStack(spacing: 2) {
            Button { state.goToPage(state.currentPageIndex - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(state.currentPageIndex == 0)
                .help("이전 페이지")
            TextField("", text: $input)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let page = Int(input) { state.goToPage(page - 1) }
                    input = "\(state.currentPageIndex + 1)"
                }
            Text("/ \(state.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            Button { state.goToPage(state.currentPageIndex + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(state.currentPageIndex >= state.pageCount - 1)
                .help("다음 페이지")
        }
        .onAppear { input = "\(state.currentPageIndex + 1)" }
        .onChange(of: state.currentPageIndex) { _, page in input = "\(page + 1)" }
    }
}
