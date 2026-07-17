import AppKit
import SwiftUI

/// 图片快速预览（FR-1.1 附属能力）：文件树中点开图片即可查看。
struct ImagePreviewView: View {
  let url: URL

  var body: some View {
    if let image = NSImage(contentsOf: url) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "photo")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("无法打开图片：\(url.lastPathComponent)")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
