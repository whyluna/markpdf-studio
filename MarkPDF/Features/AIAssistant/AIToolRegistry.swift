import Foundation

/// 工具注册表（FR-AI.5）：模型可见工具的统一定义与执行路由。
/// 策略分级——只读工具（AIWorkspaceTools 四件套）直接执行返回结果；
/// 写工具只产出提案入队等用户审查（PRD v2「写操作需用户批准」），循环内绝不落盘。
enum AIToolRegistry {
  /// 写工具单文件内容上限（字符）：提案里的内容/编辑块超限直接拒绝
  static let maxFileChars = 200_000

  // MARK: - 定义

  /// readEnabled = 检索工具（随「检索工作区」隐私开关）；writeEnabled = 写提案工具（开工作区即用）
  static func definitions(readEnabled: Bool, writeEnabled: Bool) -> [AITool] {
    var defs: [AITool] = []
    if readEnabled { defs += AIWorkspaceTools.definitions }
    if writeEnabled { defs += writeDefinitions }
    return defs
  }

  private static let writeDefinitions: [AITool] = [
    AITool(
      name: "workspace_write_file",
      description: """
        Propose creating a new Markdown file in the workspace with full content. \
        The proposal is queued for user review and only becomes a real file after approval. \
        Fails if the path already exists — use workspace_edit_file to modify existing files.
        """,
      parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"workspace-relative path ending in .md, e.g. notes/读书笔记.md"},"content":{"type":"string","description":"full file content in the app's Markdown dialect"}},"required":["path","content"]}"#
    ),
    AITool(
      name: "workspace_edit_file",
      description: """
        Propose edits to an existing Markdown file as search/replace blocks. \
        Each old_text must match the file exactly (including whitespace and indentation) \
        and be unique — include surrounding context to disambiguate. Edits apply in order. \
        The proposal is queued for user review and only takes effect after approval.
        """,
      parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"workspace-relative path of an existing .md file"},"edits":{"type":"array","items":{"type":"object","properties":{"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["old_text","new_text"]}},"replace_all":{"type":"boolean","default":false,"description":"allow old_text to match multiple places and replace all of them"}},"required":["path","edits"]}"#
    ),
    AITool(
      name: "workspace_create_folder",
      description: """
        Propose creating a folder (intermediate parents included) in the workspace. \
        Only needed when the user asks to organize files — workspace_write_file creates \
        parent folders automatically. Queued for user review like other write tools.
        """,
      parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"workspace-relative folder path"}},"required":["path"]}"#
    ),
  ]

  // MARK: - 系统提示（写作纪律 + 方言速查）

  /// 写工具使用纪律与本应用 Markdown 方言速查（追加到 system 提示；写作模式开启时）
  static func writingHint() -> String {
    """
    WRITE MODE is ON: the user's message is a writing request — they expect file changes.
    Hard rules:
    - You MUST actually call workspace_write_file / workspace_edit_file / workspace_create_folder to propose changes. NEVER claim you "have proposed/submitted/queued" anything unless a real tool call returned a "Queued for review" result this turn. The app shows review cards to the user automatically; describing changes in prose without a tool call misleads them.
    - Proposals are queued for user review and take effect only after approval. Do not re-read a file to verify your own pending proposal.
    - Batch all changes for one task. After the tool results, your final reply must be AT MOST ONE short sentence (e.g. "已提交 N 处修改，请审批") — the app shows the review card with full details; do NOT repeat the changes in prose.
    - workspace_edit_file: old_text must match exactly (whitespace, indentation, punctuation) and be unique; keep it as small as possible while still unique.
    - Prefer MANY SMALL edits (one logical change each) over one large rewrite — the app lets the user accept/reject each change individually, so small edits review much better.
    - IMAGES: only embed image files that ACTUALLY EXIST in the workspace (paths relative to the workspace root). Never invent image paths or guess file names — a non-existent path renders as a broken-image placeholder in the app, never useful content. If no real image exists, write a plain-text description instead of image syntax. NEVER copy any placeholder or error text you may have seen into the file — the file must contain real Markdown syntax only.
    The app renders an extended Markdown dialect — use it:
    - Callouts: "> [!note] Title" on its own line followed by quoted lines; types note/tip/important/warning/danger/quote.
    - Diagrams: fenced code blocks with language "mermaid" (flowchart, sequence, mindmap…).
    - Tables (GFM pipe tables), task lists "- [ ]"/"- [x]", footnotes "[^1]", strikethrough, ==highlight==.
    - Sub/superscript: H~2~O, x^2^. Math: "$…$" inline and "$$…$$" blocks (LaTeX).
    - Images: ![alt](relative.png); optional width "![alt|300](relative.png)" — existing files only, see IMAGES rule above.
    - "[TOC]" on its own line renders a table of contents.
    When taking notes about a PDF, cite pages as list items "- [p.N] 摘录…" (clickable backlinks that open the PDF at that page).
    """
  }

  // MARK: - 执行

  /// 执行环境（AIChatStore 每次 send 组装；闭包由 WindowSession 接线，测试可注入替身）
  struct Context {
    var workspaceRoot: URL?
    var workspaceFiles: [URL] = []
    var writeEnabled = false
    /// 写提案入队（主线程消费 → AIChangeStore）
    var enqueueChange: ((AIFileChange) -> Void)?
    /// 打开中文件的实时文本（文件开着时以编辑器内存为准，未落盘编辑不丢；nil = 未打开）
    var liveText: (URL) -> String? = { _ in nil }
  }

  /// 执行一次工具调用（agent 循环内 await；错误一律回文本不中断循环）
  static func execute(call: AIToolCall, context: Context) async -> String {
    let isReadTool = AIWorkspaceTools.definitions.contains { $0.name == call.name }
    if isReadTool {
      let root = context.workspaceRoot
      let files = context.workspaceFiles
      return await Task.detached(priority: .userInitiated) {
        AIWorkspaceTools.execute(call: call, workspaceRoot: root, files: files)
      }.value
    }
    guard context.writeEnabled else {
      return "Error: unknown tool '\(call.name)'."
    }
    guard let root = context.workspaceRoot else {
      return "Error: no workspace is open. Tools are unavailable."
    }
    let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    switch call.name {
    case "workspace_write_file":
      return await proposeWriteFile(arguments, root: root, context: context)
    case "workspace_edit_file":
      return await proposeEditFile(arguments, root: root, context: context)
    case "workspace_create_folder":
      return await proposeCreateFolder(arguments, root: root, context: context)
    default:
      return "Error: unknown tool '\(call.name)'."
    }
  }

  // MARK: - 写工具（校验在后台，入队在主线程）

  private static func proposeWriteFile(
    _ arguments: [String: Any], root: URL, context: Context
  ) async -> String {
    guard let rawPath = arguments["path"] as? String,
      let content = arguments["content"] as? String
    else { return "Error: missing 'path' or 'content'." }
    guard content.count <= maxFileChars else {
      return "Error: content too large (\(content.count) chars, cap \(maxFileChars)). Split the note into smaller files."
    }
    guard content.contains(where: { !$0.isWhitespace }) else {
      return "Error: 'content' is empty. Write actual note content."
    }
    guard let resolved = resolveWritePath(rawPath, root: root, requireExtension: "md") else {
      return "Error: invalid 'path' '\(rawPath)'. Use a workspace-relative path ending in .md (no '..', no absolute paths)."
    }
    let exists = await Task.detached(priority: .userInitiated) {
      FileManager.default.fileExists(atPath: resolved.url.path)
    }.value
    guard !Task.isCancelled else { return "Cancelled." }
    guard !exists else {
      return "Error: '\(resolved.relative)' already exists. Use workspace_edit_file to modify it."
    }
    await enqueue(
      AIFileChange(kind: .createFile, path: resolved.relative, content: content, edits: []),
      context: context
    )
    return "Queued for review: create '\(resolved.relative)' (\(content.count) chars). It becomes a real file only after the user approves. Do not assume it exists."
  }

  private static func proposeEditFile(
    _ arguments: [String: Any], root: URL, context: Context
  ) async -> String {
    guard let rawPath = arguments["path"] as? String else { return "Error: missing 'path'." }
    guard let rawEdits = arguments["edits"] as? [[String: Any]] else {
      return "Error: missing 'edits' (array of {old_text, new_text})."
    }
    let edits = rawEdits.enumerated().compactMap { index, dict -> (Int, AIFileChange.TextEdit)? in
      guard let old = dict["old_text"] as? String, let new = dict["new_text"] as? String else { return nil }
      return (index, AIFileChange.TextEdit(oldText: old, newText: new))
    }
    guard !edits.isEmpty else {
      return "Error: 'edits' is empty or malformed — each item needs 'old_text' and 'new_text' strings."
    }
    let joinedSize = edits.reduce(0) { $0 + $1.1.oldText.count + $1.1.newText.count }
    guard joinedSize <= maxFileChars else {
      return "Error: edits too large (\(joinedSize) chars, cap \(maxFileChars)). Use fewer, smaller edits."
    }
    guard let resolved = resolveWritePath(rawPath, root: root, requireExtension: "md") else {
      return "Error: invalid 'path' '\(rawPath)'. Use a workspace-relative path of an existing .md file."
    }
    // 基准文本：文件开着用编辑器实时文本（未落盘编辑也参与匹配），否则读盘
    let base: String?
    if let live = await MainActor.run(body: { context.liveText(resolved.url) }) {
      base = live
    } else {
      base = await Task.detached(priority: .userInitiated) {
        try? String(contentsOf: resolved.url, encoding: .utf8)
      }.value
    }
    guard let base else {
      return "Error: cannot read '\(resolved.relative)' (missing or unreadable). Check the path with workspace_list_documents."
    }
    let replaceAll = arguments["replace_all"] as? Bool ?? false
    let outcome = AIEditApplication.apply(edits.map(\.1), to: base, replaceAll: replaceAll)
    guard !Task.isCancelled else { return "Cancelled." }
    // 全部命中才入队（部分命中会让审查界面与模型认知分叉；失败明细回传模型自纠）
    guard outcome.failures.isEmpty else {
      let details = outcome.failures.sorted(by: { $0.key < $1.key }).map { index, error in
        "edits[\(index)]: \(error.guidance)"
      }.joined(separator: "; ")
      return "Error: \(outcome.failures.count) of \(edits.count) edits did not match '\(resolved.relative)' — \(details). Nothing was queued; fix old_text and retry."
    }
    await enqueue(
      AIFileChange(kind: .editFile, path: resolved.relative, content: "", edits: edits.map(\.1)),
      context: context
    )
    let summary = edits.map { "\($0.1.oldText.prefix(30).replacingOccurrences(of: "\n", with: "⏎"))" }
      .joined(separator: " | ")
    return "Queued for review: \(edits.count) edits to '\(resolved.relative)' (\(summary.prefix(200))). They take effect only after the user approves."
  }

  private static func proposeCreateFolder(
    _ arguments: [String: Any], root: URL, context: Context
  ) async -> String {
    guard let rawPath = arguments["path"] as? String else { return "Error: missing 'path'." }
    guard let resolved = resolveWritePath(rawPath, root: root, requireExtension: nil) else {
      return "Error: invalid 'path' '\(rawPath)'. Use a workspace-relative folder path."
    }
    let exists = await Task.detached(priority: .userInitiated) {
      FileManager.default.fileExists(atPath: resolved.url.path)
    }.value
    guard !Task.isCancelled else { return "Cancelled." }
    guard !exists else {
      return "Error: '\(resolved.relative)' already exists."
    }
    await enqueue(
      AIFileChange(kind: .createFolder, path: resolved.relative, content: "", edits: []),
      context: context
    )
    return "Queued for review: create folder '\(resolved.relative)'. Only needed as an explicit organization step — workspace_write_file creates parent folders automatically."
  }

  private static func enqueue(_ change: AIFileChange, context: Context) async {
    guard !Task.isCancelled, let enqueueChange = context.enqueueChange else { return }
    // execute 在并发执行器上跑：入队必须显式回主线程（AIChangeStore 是 @MainActor）
    await MainActor.run {
      guard !Task.isCancelled else { return }
      enqueueChange(change)
    }
  }

  // MARK: - 写路径解析

  /// 相对路径 → 工作区内绝对 URL（防逃逸；不要求已存在）。
  /// 返回归一后的相对路径（提案、应用、撤销全程用同一形态）
  static func resolveWritePath(
    _ relative: String, root: URL, requireExtension: String?
  ) -> (url: URL, relative: String)? {
    let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
    let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
    let rootPath = root.standardizedFileURL.path
    guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
    // standardizedFileURL 只消解 . 和 ..，不会解析工作区内符号链接。
    // 复用图片协议的「最近存在祖先解析」口径，目标文件尚不存在时也能阻止
    // workspace/link -> /outside 后经 link/new.md 写出工作区。
    let resolvedRootPath = LocalFileSchemeHandler.resolvedPath(root)
    let resolvedCandidatePath = LocalFileSchemeHandler.resolvedPath(candidate)
    guard resolvedCandidatePath.hasPrefix(resolvedRootPath + "/") else { return nil }
    // 排除名单目录（.git/node_modules/.markpdf…）与隐藏段：写进去会从文件树里消失
    let segments = candidate.path.dropFirst(rootPath.count + 1).split(separator: "/")
    guard !segments.contains(where: { $0.hasPrefix(".") }),
      !WorkspaceExcludedDirectories.isExcluded(eventPath: candidate.path, watchedRoot: rootPath)
    else { return nil }
    if let requireExtension, candidate.pathExtension.lowercased() != requireExtension { return nil }
    let normalizedRelative = segments.joined(separator: "/")
    guard !normalizedRelative.isEmpty else { return nil }
    return (candidate, normalizedRelative)
  }
}
