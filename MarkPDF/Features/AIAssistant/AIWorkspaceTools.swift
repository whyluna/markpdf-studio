import Foundation
import PDFKit

/// 工作区工具（FR-AI.2 v1.3 agent 循环）：模型自主调用的四件套（全只读、限工作区内）。
/// 定义（schema）+ 同步执行器（调用方负责后台线程）；错误一律回文本（不中断循环）。
enum AIWorkspaceTools {
  // MARK: - 限量常量

  static let searchResultCap = 3_000
  static let listCap = 100
  static let outlineCap = 2_000
  static let sectionCap = 6_000
  static let maxSearchResults = 10

  // MARK: - 工具定义（送两族 tools 参数）

  static let definitions: [AITool] = [
    AITool(
      name: "workspace_search",
      description: """
        Full-text search across all Markdown/PDF documents in the user's workspace. \
        Use when the current document and selection are not enough, or the question involves other files. \
        Use 2-5 specific keywords (Chinese or English, space-separated); retry with broader/shorter \
        keywords if results are poor. Returns up to max_results snippets with file and location.
        """,
      parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"space-separated keywords"},"max_results":{"type":"integer","default":5,"maximum":10}},"required":["query"]}"#
    ),
    AITool(
      name: "workspace_list_documents",
      description: "List all Markdown/PDF documents in the workspace (relative path, type, size). Call first when unsure what the workspace contains.",
      parametersJSON: #"{"type":"object","properties":{}}"#
    ),
    AITool(
      name: "workspace_get_outline",
      description: "Get the section outline of a document (Markdown heading tree / PDF bookmarks). Use to locate relevant sections before reading.",
      parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"workspace-relative path"}},"required":["path"]}"#
    ),
    AITool(
      name: "workspace_read_section",
      description: "Read the full text of one section of a document (section title from workspace_get_outline). Result is truncated around 6000 characters.",
      parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"section":{"type":"string","description":"section title from the outline"}},"required":["path","section"]}"#
    ),
  ]

  /// 系统提示的工具指引（v1.4 使用纪律，Cline 定义/纪律分离）+ 工作区文件清单（≤50 个）
  static func systemHint(fileNames: [String]) -> String {
    let list = fileNames.prefix(50).joined(separator: ", ")
    let more = fileNames.count > 50 ? " …and \(fileNames.count - 50) more" : ""
    return """
      You can call workspace_* tools to consult other documents in the user's workspace.
      Tool guidelines:
      - Evaluate the provided context first; call tools only for information it lacks.
      - The current document is already provided in full or in selected sections — do not re-read it with tools.
      - Typical flow: workspace_search to locate → workspace_get_outline to see structure → workspace_read_section to expand.
      - If a search returns nothing useful, retry once with fewer or broader keywords instead of repeating the same query.
      - One reasoning step per turn: base each call on the previous result.
      Workspace files: \(list)\(more)
      """
  }

  // MARK: - 执行（同步纯逻辑；调用方后台线程执行）

  /// 执行一次工具调用；任何失败返回给模型的错误说明文本（不抛错、不中断循环）
  static func execute(call: AIToolCall, workspaceRoot: URL?, files: [URL]) -> String {
    guard let workspaceRoot else {
      return "Error: no workspace is open. Tools are unavailable."
    }
    let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    switch call.name {
    case "workspace_search":
      guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        return "Error: missing 'query'. Provide 2-5 space-separated keywords."
      }
      let maxResults = min(arguments["max_results"] as? Int ?? 5, maxSearchResults)
      return search(query: query, files: files, maxResults: maxResults)
    case "workspace_list_documents":
      return listDocuments(files: files, root: workspaceRoot)
    case "workspace_get_outline":
      guard let url = resolvePath(arguments["path"] as? String, root: workspaceRoot) else {
        return "Error: invalid or missing 'path'. Use a workspace-relative path from workspace_list_documents."
      }
      return outline(of: url)
    case "workspace_read_section":
      guard let url = resolvePath(arguments["path"] as? String, root: workspaceRoot) else {
        return "Error: invalid or missing 'path'. Use a workspace-relative path from workspace_list_documents."
      }
      guard let section = arguments["section"] as? String, !section.isEmpty else {
        return "Error: missing 'section'. Get section titles via workspace_get_outline."
      }
      return readSection(of: url, titled: section)
    default:
      return "Error: unknown tool '\(call.name)'."
    }
  }

  /// 相对路径 → 工作区内绝对 URL（标准化防 ../ 逃逸；文件必须存在）
  static func resolvePath(_ relative: String?, root: URL) -> URL? {
    guard let relative, !relative.isEmpty else { return nil }
    let candidate = root.appendingPathComponent(relative).standardizedFileURL
    let rootPath = root.standardizedFileURL.path
    guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
    guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
    return candidate
  }

  // MARK: - 私有实现

  private static func search(query: String, files: [URL], maxResults: Int) -> String {
    let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard !terms.isEmpty else { return "Error: empty query." }
    var scored: [(url: URL, score: Int)] = []
    for url in files {
      let score = FullTextSearch.multiTermScore(url: url, terms: terms)
      if score > 0 { scored.append((url, score)) }
    }
    guard !scored.isEmpty else {
      return "No matches for '\(query)'. Try fewer or more general keywords, or workspace_list_documents."
    }
    var lines: [String] = []
    for entry in scored.sorted(by: { $0.score > $1.score }).prefix(maxResults) {
      // 首个命中词的定位与摘录
      let hit = terms.lazy.compactMap { term -> FullTextSearchResult? in
        switch FileNode.kind(for: entry.url, isDirectory: false) {
        case .markdown: return FullTextSearch.searchMarkdown(url: entry.url, needle: term)
        case .pdf: return FullTextSearch.searchPDF(url: entry.url, needle: term)
        default: return nil
        }
      }.first
      let anchor = hit.map { $0.kind == .pdf ? "p.\($0.location)" : "L\($0.location)" } ?? "-"
      let snippet = hit?.snippet ?? ""
      lines.append("\(entry.url.lastPathComponent) [\(anchor)] (hits: \(entry.score)) \(snippet)")
    }
    return String(lines.joined(separator: "\n").prefix(searchResultCap))
  }

  private static func listDocuments(files: [URL], root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let lines = files.prefix(listCap).map { url -> String in
      let path = url.standardizedFileURL.path
      let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
      let kind = FileNode.kind(for: url, isDirectory: false) == .pdf ? "pdf" : "md"
      return "\(relative) (\(kind), \((size ?? 0) / 1024) KB)"
    }
    let more = files.count > listCap ? "\n…and \(files.count - listCap) more" : ""
    return lines.isEmpty ? "The workspace has no Markdown/PDF documents." : lines.joined(separator: "\n") + more
  }

  private static func outline(of url: URL) -> String {
    let sections = cachedSections(of: url)
    guard !sections.isEmpty else {
      return "Error: cannot read or section '\(url.lastPathComponent)' (unsupported type or no text layer)."
    }
    return String(DocumentSectioner.outlineDigest(sections).prefix(outlineCap))
  }

  private static func readSection(of url: URL, titled title: String) -> String {
    let sections = cachedSections(of: url)
    guard !sections.isEmpty else {
      return "Error: cannot read '\(url.lastPathComponent)'."
    }
    // 精确匹配优先，其次包含匹配（模型常回传截短的标题）
    let match = sections.first { $0.title == title }
      ?? sections.first { $0.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.title) }
    guard let match else {
      let titles = sections.map(\.title).joined(separator: " / ")
      return "Error: no section titled '\(title)'. Available: \(String(titles.prefix(500)))"
    }
    let text = "[\(match.anchor)] \(match.title)\n\(match.text)"
    return text.count > sectionCap
      ? String(text.prefix(sectionCap)) + "\n…(truncated; ask for a narrower section if needed)"
      : text
  }

  private static func cachedSections(of url: URL) -> [DocumentSection] {
    DocumentSectionCache.shared.sections(for: url) {
      switch FileNode.kind(for: url, isDirectory: false) {
      case .markdown:
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return DocumentSectioner.fromMarkdown(text)
      case .pdf:
        guard let document = PDFDocument(url: url) else { return nil }
        return DocumentSectioner.fromPDF(document)
      default:
        return nil
      }
    } ?? []
  }
}
