import Foundation

/// 文件树操作错误（FR-1.2）
enum FileOperationError: LocalizedError, Equatable {
  case alreadyExists(String)
  case invalidName(String)

  var errorDescription: String? {
    switch self {
    case .alreadyExists(let name): "「\(name)」已存在"
    case .invalidName(let name): "文件名「\(name)」不合法（不能为空，且不含 / 或 :）"
    }
  }
}

/// 文件树操作服务（FR-1.2）：新建/重命名/移动/删除（入废纸篓）。
/// 协议化（开发规范 §3.2）：测试可注入 mock。
protocol FileOperations {
  func createFile(at url: URL) throws
  func createFolder(at url: URL) throws
  /// 重命名；返回新 URL（名字未变时返回原 URL）
  @discardableResult func rename(at url: URL, to newName: String) throws -> URL
  /// 移动到目标文件夹；返回新 URL（原地不动时返回原 URL）
  @discardableResult func move(at url: URL, toFolder folder: URL) throws -> URL
  func trash(at url: URL) throws
  /// 生成不冲突的文件名：未命名.md → 未命名 2.md → …
  func uniqueFileURL(in folder: URL, baseName: String, ext: String) -> URL
  func uniqueFolderURL(in folder: URL, baseName: String) -> URL
}

final class LiveFileOperations: FileOperations {
  private let fm = FileManager.default

  func createFile(at url: URL) throws {
    guard !fm.fileExists(atPath: url.path) else {
      throw FileOperationError.alreadyExists(url.lastPathComponent)
    }
    try Data().write(to: url, options: .atomic)
  }

  func createFolder(at url: URL) throws {
    guard !fm.fileExists(atPath: url.path) else {
      throw FileOperationError.alreadyExists(url.lastPathComponent)
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
  }

  @discardableResult
  func rename(at url: URL, to newName: String) throws -> URL {
    let name = newName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
      throw FileOperationError.invalidName(newName)
    }
    let target = url.deletingLastPathComponent().appendingPathComponent(name)
    guard target != url else { return url }
    guard !fm.fileExists(atPath: target.path) else {
      throw FileOperationError.alreadyExists(name)
    }
    try fm.moveItem(at: url, to: target)
    return target
  }

  @discardableResult
  func move(at url: URL, toFolder folder: URL) throws -> URL {
    let target = folder.appendingPathComponent(url.lastPathComponent)
    guard target != url else { return url }
    guard !fm.fileExists(atPath: target.path) else {
      throw FileOperationError.alreadyExists(url.lastPathComponent)
    }
    try fm.moveItem(at: url, to: target)
    return target
  }

  func trash(at url: URL) throws {
    try fm.trashItem(at: url, resultingItemURL: nil)
  }

  func uniqueFileURL(in folder: URL, baseName: String, ext: String) -> URL {
    var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent("\(baseName) \(n).\(ext)")
      n += 1
    }
    return candidate
  }

  func uniqueFolderURL(in folder: URL, baseName: String) -> URL {
    var candidate = folder.appendingPathComponent(baseName)
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent("\(baseName) \(n)")
      n += 1
    }
    return candidate
  }
}
