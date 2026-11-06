import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showThumbnails = false

    var body: some View {
        HSplitView {
            if showThumbnails && state.document != nil {
                ThumbnailStrip(pdfView: state.pdfView)
                    .frame(minWidth: 110, idealWidth: 140, maxWidth: 220)
            }
            VSplitView {
                reader
                    .frame(minHeight: 200)
                if state.showTerminal {
                    TerminalPanel()
                        .frame(minHeight: 120, idealHeight: 240)
                }
            }
            .frame(minWidth: 420)
            if state.showSidePanel {
                SidePanel()
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 600)
            }
        }
        .navigationTitle(state.title)
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in AppState.shared.open(url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var reader: some View {
        if state.document == nil {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("PDF를 끌어다 놓거나 ⌘O로 여세요")
                    .foregroundStyle(.secondary)
                Button("열기…") { state.presentOpenPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PDFKitView(pdfView: state.pdfView)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("썸네일")
        }
        ToolbarItemGroup(placement: .principal) {
            if state.document != nil {
                PageNavigator()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.showTerminal.toggle() } label: { Image(systemName: "terminal") }
                .help("터미널 (⌃`)")
            Button { state.showSidePanel.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("AI · 메모 패널")
        }
    }
}

private struct PageNavigator: View {
    @EnvironmentObject private var state: AppState
    @State private var input = ""

    var body: some View {
        HStack(spacing: 4) {
            Button { state.goToPage(state.currentPageIndex - 1) } label: { Image(systemName: "chevron.left") }
            TextField("", text: $input)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let page = Int(input) { state.goToPage(page - 1) }
                    input = "\(state.currentPageIndex + 1)"
                }
            Text("/ \(state.pageCount)").monospacedDigit().foregroundStyle(.secondary)
            Button { state.goToPage(state.currentPageIndex + 1) } label: { Image(systemName: "chevron.right") }
        }
        .onAppear { input = "\(state.currentPageIndex + 1)" }
        .onChange(of: state.currentPageIndex) { _, page in input = "\(page + 1)" }
    }
}

struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

private struct ThumbnailStrip: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = CGSize(width: 90, height: 120)
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}
