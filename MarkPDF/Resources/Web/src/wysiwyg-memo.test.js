// 装饰层 (doc, 语法树) 记忆化（批次三·性能）：
// 纯选区交易（方向键/点击）不得重复全文扫描（scanExtended 调用数不增），
// 且复用缓存的装饰输出与全量重建完全一致；文档变化必须失效重建。
import { describe, it, expect, vi, beforeEach } from "vitest";

// 注入计数器：包装 scanExtended 统计全文扫描次数（实现不变，仅计数）
let scanCalls = 0;
vi.mock("./extended.js", async (importOriginal) => {
  const mod = await importOriginal();
  return {
    ...mod,
    scanExtended: (...args) => {
      scanCalls++;
      return mod.scanExtended(...args);
    },
  };
});

import { EditorState } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { wysiwyg } from "./wysiwyg.js";

// 覆盖三类扩展语法 + 既有装饰，确保缓存路径参与所有分支
const DOC = `# 标题 $x$ ==h==

行内 $a+b$ 公式与 ==高亮==，脚注 [^a] 与 [^b]。

[^a]: 定义 *含强调*
[^b]: 定义二

| 表 $x$ | ==y== |
| --- | --- |
| a | b |

- [x] 任务 ==项==

![img](a.png) [链接 $q$](u)
`;

// 序列化装饰集：范围 + 类型 + 区分性字段（mark class / widget 构造名与内容标识）
function serialize(deco) {
  const out = [];
  deco.between(0, 1e9, (from, to, v) => {
    const w = v.spec?.widget;
    out.push([
      from,
      to,
      v.isReplace ? "R" : "M",
      v.spec?.class ?? "",
      w ? w.constructor.name : "",
      w?.source ?? w?.latex ?? w?.label ?? w?.src ?? w?.lang ?? "",
    ]);
  });
  return out;
}

function makeState(doc, anchor, field) {
  return EditorState.create({
    doc,
    selection: { anchor },
    extensions: [markdown({ base: markdownLanguage }), field],
  });
}

describe("wysiwyg (doc, 语法树) 记忆化", () => {
  beforeEach(() => {
    scanCalls = 0;
  });

  it("纯选区交易复用缓存：不重复全文扫描，输出与全量重建一致", () => {
    const field = wysiwyg(false);
    let s = makeState(DOC, 0, field);
    expect(scanCalls).toBe(1);

    // 连续纯选区交易（方向键/点击等价物），落点覆盖各装饰区
    for (const pos of [2, 14, 30, 60, 90, 120, s.doc.length]) {
      s = s.update({ selection: { anchor: Math.min(pos, s.doc.length) } }).state;
    }
    expect(scanCalls).toBe(1, "纯选区交易不得重新全文扫描");

    // 输出一致性：同文档同选区，缓存路径 vs 全新字段全量重建
    const refField = wysiwyg(false);
    const ref = makeState(DOC, s.selection.main.anchor, refField);
    expect(serialize(s.field(field))).toEqual(serialize(ref.field(refField)));
  });

  it("文档变化失效重建：扫描重新执行，之后的选区交易再次走缓存", () => {
    const field = wysiwyg(false);
    let s = makeState(DOC, 0, field);
    expect(scanCalls).toBe(1);

    s = s.update({ changes: { from: 0, insert: "前言 " } }).state;
    expect(scanCalls).toBe(2, "文档变化必须重新全文扫描");

    s = s.update({ selection: { anchor: 3 } }).state;
    expect(scanCalls).toBe(2, "变化后的纯选区交易应再次走缓存");

    // 变化后输出一致性：与全新字段全量重建对齐
    const refField = wysiwyg(false);
    const ref = makeState(s.doc.toString(), 3, refField);
    expect(serialize(s.field(field))).toEqual(serialize(ref.field(refField)));
  });

  it("reading 模式（alwaysRender）同样记忆化", () => {
    const field = wysiwyg(true);
    let s = makeState(DOC, 0, field);
    expect(scanCalls).toBe(1);
    s = s.update({ selection: { anchor: 20 } }).state;
    expect(scanCalls).toBe(1);
  });
});
