import Foundation

/// 流式工具调用重组器（FR-AI.2 v1.3）：两族的 delta 碎片 → 完整 AIToolCall 列表。
/// 纯状态机可单测；防御兼容端点的边角差异（缺 index / 重复 id）。
enum AIToolCallAccumulator {
  /// OpenAI 兼容族：按 `delta.tool_calls[].index` 为槽位主键拼接 arguments 片段。
  /// 首片带 id/name，后续片只有 arguments 碎片；缺 index 时回退「最后一个槽位」
  struct OpenAI {
    private struct Slot {
      var id: String = ""
      var name: String = ""
      var arguments: String = ""
    }
    private var slots: [Int: Slot] = [:]
    private var lastIndex = 0

    var isEmpty: Bool { slots.isEmpty }

    mutating func ingest(_ deltas: [AIChunkDecoder.OpenAIToolCallDelta]) {
      for delta in deltas {
        let index = delta.index ?? lastIndex
        lastIndex = index
        var slot = slots[index] ?? Slot()
        // 部分端点在非首片重复发 id/name：非空才覆盖，避免碎片清空
        if let id = delta.id, !id.isEmpty { slot.id = id }
        if let name = delta.name, !name.isEmpty { slot.name = name }
        if let fragment = delta.argumentsFragment { slot.arguments += fragment }
        slots[index] = slot
      }
    }

    func finalize() -> [AIToolCall] {
      slots.sorted { $0.key < $1.key }.compactMap { _, slot in
        guard !slot.name.isEmpty else { return nil }
        return AIToolCall(
          id: slot.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : slot.id,
          name: slot.name,
          arguments: slot.arguments.isEmpty ? "{}" : slot.arguments
        )
      }
    }
  }

  /// Anthropic 族：content_block_start(tool_use) 记 id/name，
  /// input_json_delta.partial_json 逐片拼接
  struct Anthropic {
    private struct Slot {
      let id: String
      let name: String
      var partialJSON: String = ""
    }
    private var slots: [Int: Slot] = [:]

    var isEmpty: Bool { slots.isEmpty }

    mutating func blockStart(index: Int, id: String, name: String) {
      slots[index] = Slot(id: id, name: name)
    }

    mutating func ingest(index: Int, partial: String) {
      slots[index]?.partialJSON += partial
    }

    func finalize() -> [AIToolCall] {
      slots.sorted { $0.key < $1.key }.map { _, slot in
        AIToolCall(
          id: slot.id,
          name: slot.name,
          arguments: slot.partialJSON.isEmpty ? "{}" : slot.partialJSON
        )
      }
    }
  }
}
