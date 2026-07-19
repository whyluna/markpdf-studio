// WYSIWYG 装饰层（src/wysiwyg.js）集成测试：对刁钻文档断言 replace 装饰两两不重叠
// （CM6 硬约束：replace 装饰互相重叠会导致渲染异常），并普查渲染态 widget 数量。
import { describe, it, expect } from "vitest";
import { EditorState } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { wysiwyg } from "./wysiwyg.js";

// 覆盖：标题内公式/高亮、行内/块级/行内块级公式、货币、高亮嵌套与含公式、
// 脚注引用与定义行、表格/行内代码/代码块/图片 alt 内的排除、链接文字内公式
const DOC = `# 标题 $x$ ==h==

行内 $a+b$ 与块内 $$c+d$$ 同行，货币 $5,$5 不算。

$$
\\int_0^1 *不是强调* x\\,dx
$$

==高亮 *含强调* 与 $x$ 公式== 嵌套 ==a ==b== c==

[^a] 引用与 [^b]，再 [^a]。

[^a]: 定义 *含强调* 与 $y$
[^b]: 定义二

| 表 $x$ | ==y== |
| --- | --- |
| [^c] | $z$ |

\`$code ==x== [^d]\`

\`\`\`
$$
in fence
$$
\`\`\`

![img $x$](a.png) [$q$](u)

- [x] 任务 ==项==
`;

function collectReplaces(deco) {
  const ranges = [];
  deco.between(0, 1e9, (from, to, v) => {
    if (v.isReplace) ranges.push([from, to, v.spec?.widget?.constructor?.name ?? "hide"]);
  });
  ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  return ranges;
}

function expectNoOverlap(state, field) {
  const ranges = collectReplaces(state.field(field));
  for (let i = 1; i < ranges.length; i++) {
    // 相邻两个 replace 范围不得相交
    expect(ranges[i][0]).toBeGreaterThanOrEqual(ranges[i - 1][1]);
  }
  return ranges;
}

describe("wysiwyg 装饰层（FR-2.4 扩展语法集成）", () => {
  const field = wysiwyg(false);
  const fieldRO = wysiwyg(true);
  const state = EditorState.create({
    doc: DOC,
    extensions: [markdown({ base: markdownLanguage }), field, fieldRO],
  });

  it("reading 模式（全渲染）：replace 无重叠，widget 普查符合预期", () => {
    const ranges = expectNoOverlap(state, fieldRO);
    const census = {};
    for (const [, , name] of ranges) census[name] = (census[name] ?? 0) + 1;
    // 7 个公式：标题 $x$、$a+b$、$$c+d$$（行内块级）、块级 $$..$$、高亮内 $x$、定义行 $y$、链接文字 $q$
    // （表格/行内代码/代码块/图片 alt 内的 $ 被排除）
    expect(census.MathWidget).toBe(7);
    // 3 个脚注引用：[^a]、[^b]、第二个 [^a]（表格内 [^c] 与代码内 [^d] 被排除）
    expect(census.FootnoteRefWidget).toBe(3);
    // 既有功能不受影响
    expect(census.TableWidget).toBe(1);
    expect(census.ImageWidget).toBe(1);
    expect(census.CheckboxWidget).toBe(1);
  });

  it("wysiwyg 模式：逐行落光标重渲染后 replace 均无重叠", () => {
    let s = state;
    expectNoOverlap(s, field);
    for (let n = 1; n <= state.doc.lines; n++) {
      s = s.update({ selection: { anchor: state.doc.line(n).from } }).state;
      expectNoOverlap(s, field);
    }
  });
});
