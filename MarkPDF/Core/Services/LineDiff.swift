import Foundation

/// 行级 diff（FR-AI.6）：Myers O(ND) 最短编辑脚本 + 上下文归组 hunk。
/// 零三方依赖（开发规范 §1）；id 全部由内容位置决定（重算稳定——
/// 审查勾选状态在文件未变时可跨重算保留）。
enum LineDiff {
  enum Kind: Equatable, Codable {
    case context
    case removed
    case added
  }

  /// diff 中的一行（上下文/删除/新增；行号 1 起）
  struct Line: Equatable, Identifiable, Codable {
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?

    var id: String {
      let marker = kind == .added ? "+" : kind == .removed ? "-" : "="
      return "\(marker)o\(oldNumber ?? -1)n\(newNumber ?? -1)"
    }
  }

  /// 一个 hunk：@@ -oldStart,oldCount +newStart,newCount @@（行号 1 起、含上下文；
  /// 纯新增 hunk 的 oldStart = 插入点行号、oldCount = 0）
  struct Hunk: Equatable, Identifiable, Codable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [Line]

    var id: String { "\(oldStart).\(oldCount).\(newStart).\(newCount)" }
    var changeCount: Int { lines.filter { $0.kind != .context }.count }
    var isPureAddition: Bool { oldCount == 0 }
    var isPureDeletion: Bool { newCount == 0 }
  }

  // MARK: - 对外入口

  /// 计算行级 diff 并按上下文归组（context = 变更行前后保留的环境行数）
  static func diff(_ old: String, _ new: String, context: Int = 3) -> [Hunk] {
    guard old != new else { return [] }
    let a = splitLines(old)
    let b = splitLines(new)
    let lines = annotatedLines(a, b)
    return groupHunks(lines, context: max(context, 0))
  }

  /// 把「勾选接受的 hunk」拼回旧文本，得到应用结果（git add -p 语义：
  /// 拒绝的 hunk 保留其旧文本区间原样；hunks 须来自同一份 diff(old, proposed)）
  static func applying(_ hunks: [Hunk], accepted: Set<String>, to old: String) -> String {
    guard !hunks.isEmpty else { return old }
    let oldLines = splitLines(old)
    var result: [String] = []
    var cursor = 0  // oldLines 已拷贝到的下标（0 起）
    for hunk in hunks.sorted(by: { $0.oldStart < $1.oldStart }) {
      let begin = min(max(hunk.oldStart - 1, cursor), oldLines.count)
      result += oldLines[cursor..<begin]
      cursor = begin
      let oldEnd = min(hunk.oldStart - 1 + hunk.oldCount, oldLines.count)
      if accepted.contains(hunk.id) {
        // 接受：按序写出上下文行与新增行（删除行不写——旧文本被替换）；
        // 上下文行即旧区间内的同文行，必须写出，否则 hunk 覆盖的旧区间被整段丢掉
        result += hunk.lines.filter { $0.kind != .removed }.map(\.text)
      } else {
        // 拒绝：旧区间原样保留
        result += oldLines[cursor..<oldEnd]
      }
      cursor = oldEnd
    }
    if cursor < oldLines.count {
      result += oldLines[cursor...]
    }
    var joined = result.joined(separator: "\n")
    if old.hasSuffix("\n"), !joined.isEmpty {
      joined += "\n"
    }
    return joined
  }

  /// 行切分：保留空行；末尾换行不产生空尾行
  static func splitLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var parts = text.components(separatedBy: "\n")
    if text.hasSuffix("\n") { parts.removeLast() }
    return parts
  }

  // MARK: - 内部

  /// 编辑脚本回放成带行号的行序列（文本取自 a/b）
  private static func annotatedLines(_ a: [String], _ b: [String]) -> [Line] {
    var lines: [Line] = []
    var oi = 0, ni = 0
    for op in editScript(a, b) {
      switch op.kind {
      case .equal:
        for _ in 0..<op.count {
          oi += 1
          ni += 1
          lines.append(Line(kind: .context, text: a[oi - 1], oldNumber: oi, newNumber: ni))
        }
      case .removed:
        for _ in 0..<op.count {
          oi += 1
          lines.append(Line(kind: .removed, text: a[oi - 1], oldNumber: oi, newNumber: nil))
        }
      case .added:
        for _ in 0..<op.count {
          ni += 1
          lines.append(Line(kind: .added, text: b[ni - 1], oldNumber: nil, newNumber: ni))
        }
      }
    }
    return lines
  }

  /// 变更行按 context 上下文扩展后归组（相邻/重叠区间合并为一个 hunk）
  private static func groupHunks(_ lines: [Line], context: Int) -> [Hunk] {
    let changeIndices = lines.indices.filter { lines[$0].kind != .context }
    guard !changeIndices.isEmpty else { return [] }

    // 变更段扩展为 [low, high]（闭区间），相邻或重叠则合并
    var ranges: [(low: Int, high: Int)] = []
    for index in changeIndices {
      let low = max(index - context, 0)
      let high = min(index + context, lines.count - 1)
      if var last = ranges.last, low <= last.high + 1 {
        last.high = max(last.high, high)
        ranges[ranges.count - 1] = last
      } else {
        ranges.append((low, high))
      }
    }

    return ranges.map { range in
      let slice = Array(lines[range.low...range.high])
      let oldNumbers = slice.compactMap(\.oldNumber)
      let newNumbers = slice.compactMap(\.newNumber)
      // 纯新增（无旧行）：插入点 = 前一旧行 +1（段首即文档首则 1）
      let oldStart = oldNumbers.first
        ?? ((range.low > 0 ? lines[range.low - 1].oldNumber : nil) ?? 0) + 1
      let newStart = newNumbers.first
        ?? ((range.low > 0 ? lines[range.low - 1].newNumber : nil) ?? 0) + 1
      return Hunk(
        oldStart: oldStart,
        oldCount: oldNumbers.count,
        newStart: newStart,
        newCount: newNumbers.count,
        lines: slice
      )
    }
  }

  // MARK: - Myers 最短编辑脚本

  private enum OpKind {
    case equal
    case removed
    case added
  }

  private struct Op {
    let kind: OpKind
    let count: Int
  }

  /// 首尾公共段剪枝 + Myers 中段；返回覆盖全序列的编辑脚本
  private static func editScript(_ a: [String], _ b: [String]) -> [Op] {
    var start = 0
    while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
    var endA = a.count, endB = b.count
    while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }

    var ops: [Op] = []
    if start > 0 { ops.append(Op(kind: .equal, count: start)) }
    ops += myers(Array(a[start..<endA]), Array(b[start..<endB]))
    if a.count - endA > 0 { ops.append(Op(kind: .equal, count: a.count - endA)) }
    return ops
  }

  /// Myers 贪心：线性 V 数组逐轮快照，命中终点后回溯（O((N+M)D)）
  private static func myers(_ a: [String], _ b: [String]) -> [Op] {
    let n = a.count, m = b.count
    guard n + m > 0 else { return [] }
    let offset = n + m
    var v = [Int](repeating: 0, count: 2 * (n + m) + 1)
    var trace: [[Int]] = []
    var foundD = -1
    outer: for d in 0...(n + m) {
      trace.append(v)
      var k = -d
      while k <= d {
        let x: Int
        if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
          x = v[k + 1 + offset]  // 向下：新增 b 行
        } else {
          x = v[k - 1 + offset] + 1  // 向右：删除 a 行
        }
        var y = x - k
        var xx = x
        while xx < n, y < m, a[xx] == b[y] {
          xx += 1
          y += 1
        }
        v[k + offset] = xx
        if xx >= n, y >= m {
          foundD = d
          break outer
        }
        k += 2
      }
    }
    guard foundD >= 0 else { return [] }

    var ops: [Op] = []
    var x = n, y = m
    for d in stride(from: foundD, through: 0, by: -1) {
      let vv = trace[d]
      let k = x - y
      let prevK: Int
      if k == -d || (k != d && vv[k - 1 + offset] < vv[k + 1 + offset]) {
        prevK = k + 1
      } else {
        prevK = k - 1
      }
      let prevX = vv[prevK + offset]
      let prevY = prevX - prevK
      while x > prevX, y > prevY {
        ops.append(Op(kind: .equal, count: 1))
        x -= 1
        y -= 1
      }
      if d > 0 {
        if x == prevX {
          ops.append(Op(kind: .added, count: 1))
          y -= 1
        } else {
          ops.append(Op(kind: .removed, count: 1))
          x -= 1
        }
      }
    }
    return coalesce(ops.reversed())
  }

  /// 相邻同种操作合并
  private static func coalesce(_ ops: [Op]) -> [Op] {
    var result: [Op] = []
    for op in ops {
      if let last = result.last, last.kind == op.kind {
        result[result.count - 1] = Op(kind: last.kind, count: last.count + op.count)
      } else {
        result.append(op)
      }
    }
    return result
  }
}
