import SwiftUI

/// PDF 页内查找栏（FR-3.4）：输入即搜（防抖）、计数、上一个/下一个、Esc 关闭。
struct PDFFindBarView: View {
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @FocusState private var fieldFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("在文档中查找…", text: $pdfStore.findQuery)
        .textFieldStyle(.plain)
        .focused($fieldFocused)
        .onSubmit {
          pdfStore.findNext()
        }
        .onExitCommand {
          pdfStore.closeFindBar()
        }
      Text(pdfStore.matchCountText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minWidth: 50)
      Button(action: pdfStore.findPrevious) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .help("上一个（⇧⌘G）")
      Button(action: pdfStore.findNext) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .help("下一个（⌘G）")
      Button(action: pdfStore.closeFindBar) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("关闭（Esc）")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .onAppear {
      fieldFocused = true
    }
  }
}

#Preview {
  PDFFindBarView()
    .environmentObject(PDFReaderStore())
    .frame(width: 600)
}
