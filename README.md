# MarkPDF Studio

macOS 原生 Markdown + PDF 阅读编辑工作台：在一个窗口内完成「管理文件 → 阅读并标注 PDF → 编写 Markdown 笔记 → 双向关联」的闭环。

- **需求文档 / 开发规范**：见 [`docs/`](docs/)
- **UI 设计基准**：见 [`prototype/index.html`](prototype/index.html)（浏览器打开即可交互预览）
- **目标平台**：macOS 13+（Apple Silicon / Intel）

## 技术栈

Swift 5.9 · SwiftUI + AppKit · PDFKit · WKWebView（CodeMirror 6 编辑器内核）· XcodeGen 工程生成

## 本地开发

```bash
# 前置：Xcode 15+，安装 XcodeGen
brew install xcodegen

git clone git@github.com:whyluna/markpdf-studio.git
cd markpdf-studio

# 生成 Xcode 工程（.xcodeproj 不入库，由 project.yml 生成）
xcodegen generate

open MarkPDF.xcodeproj   # Cmd+R 运行
```

## CI

每次 push 到 `main`（非文档改动）自动在 GitHub Actions macOS runner 上执行 `xcodebuild build test`，文档/原型改动不触发构建以节省额度。

## 协作约定

- 分支：`main` 直推，Conventional Commits
- 每完成一个功能或修复一个 bug 即 commit + push
- 视觉与交互以 `prototype/index.html` 为唯一基准
