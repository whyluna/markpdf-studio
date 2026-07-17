# MarkPDF Studio

macOS 原生 Markdown + PDF 阅读编辑工作台：在一个窗口内完成「管理文件 → 阅读并标注 PDF → 编写 Markdown 笔记 → 双向关联」的闭环。

- **需求文档 / 开发规范**：见 [`docs/`](docs/)
- **UI 设计基准**：见 [`prototype/index.html`](prototype/index.html)（浏览器打开即可交互预览）
- **目标平台**：macOS 13+（Apple Silicon / Intel）

## 技术栈

Swift 5.9 · SwiftUI + AppKit · PDFKit · WKWebView（CodeMirror 6 编辑器内核）· XcodeGen 工程生成

## 本地开发

```bash
# 前置：Xcode 15+，Node.js 20+（编辑器内核构建），XcodeGen
brew install node xcodegen

git clone git@github.com:whyluna/markpdf-studio.git
cd markpdf-studio

# 生成 Xcode 工程（.xcodeproj 不入库，由 project.yml 生成）
xcodegen generate

open MarkPDF.xcodeproj   # Cmd+R 运行
```

首次编译时若 `MarkPDF/Resources/Web/dist/` 缺失，preBuild 脚本会自动执行 `npm ci && npm run build` 构建编辑器内核；也可手动构建：

```bash
cd MarkPDF/Resources/Web && npm ci && npm run build
```

## 使用

- **⌘O** 打开一个文件夹作为工作区，左侧文件树展示其中的 Markdown / PDF / 图片
- 点击 `.md` 进入编辑（所见即所得 / 源码 / 阅读 三模式）；停止输入 0.5 秒自动保存，**⌘S** 立即保存
- 点击 `.pdf` / 图片直接预览（PDF 标注能力在 M2 提供）

## CI

[`docs/macos-ci.yml`](docs/macos-ci.yml) 是现成的 GitHub Actions 模板（Node 环境 → 构建 Web 内核 → XcodeGen → 编译 + 测试）。启用方式：复制为 `.github/workflows/macos.yml` 后 push（自动化 token 无 workflow scope，需手动添加一次）。

## 协作约定

- 分支：`main` 直推，Conventional Commits
- 每完成一个功能或修复一个 bug 即 commit + push
- 视觉与交互以 `prototype/index.html` 为唯一基准
