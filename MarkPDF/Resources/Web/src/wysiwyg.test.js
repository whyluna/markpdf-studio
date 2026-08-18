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

- 一层
  - 二层
    - 三层

3. 第三项
4. 第四项

H~2~O 与 x^2^，:smile: 与 :not_in_table:，时间 10:30:45

> [!NOTE]
> GitHub 风格提示块

> [!tip]+ 自定义标题
> Obsidian 风格 **提示**

\`\`\`mermaid
graph TD
  A --> B
\`\`\`
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
    // 美化第二阶段：列表 bullet（三层嵌套各一个）、有序序号（保留源码文本）
    expect(census.ListBulletWidget).toBe(3);
    expect(census.ListNumWidget).toBe(2);
    // emoji：:smile: 命中码表；:not_in_table: 与时间串 :30: 查无 → 源码原样（无 widget）
    expect(census.EmojiWidget).toBe(1);
    // P1：callout 徽章（GitHub NOTE + Obsidian tip 自定义标题）、mermaid 块整体替换
    expect(census.CalloutBadgeWidget).toBe(2);
    expect(census.MermaidWidget).toBe(1);
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

// 批次四·P1 回归：`[^a](x)` 被 lezer 整体解析为 Link，前缀不得再生成脚注 widget
// （修复前：脚注 replace 与 Link 隐藏装饰 replace 相交——CM 明令禁止、行为未定义）
describe("脚注引用与带目标链接的装饰重叠（[^注](2024)）", () => {
  const DOC2 = "见 [^注](2024) 与纯引用 [^a]。\n\n[^a]: 定义\n";
  const field2 = wysiwyg(false);
  const state2 = EditorState.create({
    doc: DOC2,
    extensions: [markdown({ base: markdownLanguage }), field2],
  });
  const linkFrom = DOC2.indexOf("[^注]");
  const linkTo = linkFrom + "[^注](2024)".length;

  it("replace 装饰无重叠", () => {
    expectNoOverlap(state2, field2);
    // 光标逐行移动后同样无重叠
    let s = state2;
    for (let n = 1; n <= state2.doc.lines; n++) {
      s = s.update({ selection: { anchor: state2.doc.line(n).from } }).state;
      expectNoOverlap(s, field2);
    }
  });

  it("[^注](2024) 整体按链接渲染：无 FootnoteRefWidget，带 cm-link 标记", () => {
    let footnoteOnLink = false;
    let linkMark = false;
    state2.field(field2).between(0, 1e9, (from, to, v) => {
      if (v.isReplace && v.spec?.widget?.constructor?.name === "FootnoteRefWidget") {
        if (from < linkTo && to > linkFrom) footnoteOnLink = true;
      }
      if (!v.isReplace && v.spec?.class === "cm-link" && from <= linkFrom && to >= linkTo) {
        linkMark = true;
      }
    });
    expect(footnoteOnLink).toBe(false);
    expect(linkMark).toBe(true);
  });

  it("纯脚注引用 [^a]（无括号后缀）仍渲染为上标", () => {
    let count = 0;
    state2.field(field2).between(0, 1e9, (_f, _t, v) => {
      if (v.isReplace && v.spec?.widget?.constructor?.name === "FootnoteRefWidget") count++;
    });
    expect(count).toBe(1);
  });
});

// 美化第二阶段：列表/上下标/emoji/段距装饰
describe("列表、上下标、emoji 与段落空行装饰", () => {
  const DOC3 = [
    "段落一",
    "",
    "- 顶层",
    "  - 嵌套",
    "- [ ] 待办",
    "- [x] 完成",
    "",
    "1. 第一",
    "",
    "```",
    "",
    "```",
    "",
    "H~2~O x^2^ :rocket:",
    "",
    "尾段",
  ].join("\n");
  const field3 = wysiwyg(true); // reading：全渲染
  const state3 = EditorState.create({
    doc: DOC3,
    extensions: [markdown({ base: markdownLanguage }), field3],
  });

  const widgetCensus = () => {
    const census = {};
    state3.field(field3).between(0, 1e9, (_f, _t, v) => {
      if (v.isReplace) {
        const key = v.spec?.widget?.constructor?.name ?? "hide";
        census[key] = (census[key] ?? 0) + 1;
      }
    });
    return census;
  };

  it("bullet 按层级取字形、序号保留源码文本、任务项隐藏 mark", () => {
    const census = widgetCensus();
    expect(census.ListBulletWidget).toBe(2); // 顶层 + 嵌套（两个任务项走隐藏分支）
    expect(census.ListNumWidget).toBe(1);
    expect(census.CheckboxWidget).toBe(2);
    // 嵌套深度：第二个 bullet 的 depth 为 1（◦ 层）
    const depths = [];
    state3.field(field3).between(0, 1e9, (_f, _t, v) => {
      const w = v.spec?.widget;
      if (v.isReplace && w?.constructor?.name === "ListBulletWidget") depths.push(w.depth);
    });
    expect(depths).toEqual([0, 1]);
    // 有序序号保留源码文本「1.」
    let numText = null;
    state3.field(field3).between(0, 1e9, (_f, _t, v) => {
      const w = v.spec?.widget;
      if (v.isReplace && w?.constructor?.name === "ListNumWidget") numText = w.text;
    });
    expect(numText).toBe("1.");
  });

  it("上下标：内容带样式标记、定界符隐藏", () => {
    let subMark = false;
    let supMark = false;
    let hiddenTildes = 0;
    // Subscript/Superscript 节点只覆盖定界符+内容（~2~ / ^2^），不含前后文字
    const subFrom = DOC3.indexOf("~2~");
    const supFrom = DOC3.indexOf("^2^");
    state3.field(field3).between(0, 1e9, (from, to, v) => {
      if (!v.isReplace && v.spec?.class === "cm-sub" && from <= subFrom && to >= subFrom + 3) subMark = true;
      if (!v.isReplace && v.spec?.class === "cm-sup" && from <= supFrom && to >= supFrom + 3) supMark = true;
      if (v.isReplace && !v.spec?.widget && from >= subFrom && to <= subFrom + 3) hiddenTildes++;
    });
    expect(subMark).toBe(true);
    expect(supMark).toBe(true);
    expect(hiddenTildes).toBe(2); // 两侧 ~
  });

  it("emoji 命中码表生成 widget", () => {
    const census = widgetCensus();
    expect(census.EmojiWidget).toBe(1);
  });

  it("段落空行压行高；代码块内空行不参与", () => {
    const sepLines = [];
    const fenceStart = DOC3.indexOf("```");
    state3.field(field3).between(0, 1e9, (from, _t, v) => {
      if (!v.isReplace && v.spec?.class === "cm-sep-line") sepLines.push(state3.doc.lineAt(from).number);
    });
    const blankLineNumbers = [];
    let pos = 0;
    DOC3.split("\n").forEach((text, i) => {
      if (text.trim() === "") blankLineNumbers.push(i + 1);
      pos += text.length + 1;
    });
    // fence 内的空行（第 11 行）不得出现在 sep 列表
    const fenceInnerBlank = 11;
    expect(sepLines).not.toContain(fenceInnerBlank);
    expect(sepLines).toEqual(blankLineNumbers.filter((n) => n !== fenceInnerBlank));
  });
});

// P1：callout 行着色/自定义标题、表格单元格公式、mermaid 懒加载边界
describe("P1 装饰：callout、表格单元格公式、mermaid", () => {
  const DOC4 = [
    "> [!WARNING]",
    "> 警告内容 **加粗**",
    "",
    "> [!success] 通过",
    "> 成功块",
    "",
    "> 普通引用",
    "",
    "| 公式 | 高亮 |",
    "| --- | --- |",
    "| $a+b$ | ==重点== |",
    "| 纯文本 | `code` |",
    "",
    "```mermaid",
    "pie",
    "  \"A\": 60",
    "  \"B\": 40",
    "```",
    "",
    "```mermaid",
    "这不是合法图表",
    "```",
  ].join("\n");
  const field4 = wysiwyg(true);
  const state4 = EditorState.create({
    doc: DOC4,
    extensions: [markdown({ base: markdownLanguage }), field4],
  });

  it("callout：徽章类型折叠正确（WARNING→warning；success→tip）+ 行类着色；普通引用不受影响", () => {
    const badges = [];
    const lineClasses = {};
    state4.field(field4).between(0, 1e9, (from, _t, v) => {
      const w = v.spec?.widget;
      if (v.isReplace && w?.constructor?.name === "CalloutBadgeWidget") badges.push({ type: w.type, title: w.title });
      if (!v.isReplace && v.spec?.class?.startsWith("cm-callout ")) {
        const n = state4.doc.lineAt(from).number;
        lineClasses[n] = v.spec.class;
      }
    });
    expect(badges).toEqual([
      { type: "warning", title: null }, // 无自定义标题 → 默认
      { type: "tip", title: "通过" }, // success 折叠到 tip + 自定义标题
    ]);
    expect(lineClasses[1]).toContain("cm-callout-warning");
    expect(lineClasses[2]).toContain("cm-callout-last");
    expect(lineClasses[4]).toContain("cm-callout-tip");
    // 普通引用（第 7 行）不得带 callout 类
    expect(lineClasses[7]).toBeUndefined();
  });

  it("表格单元格：行内公式进 model（math 段），高亮叠加 hl 标记", () => {
    let tableWidget = null;
    state4.field(field4).between(0, 1e9, (_f, _t, v) => {
      const w = v.spec?.widget;
      if (v.isReplace && w?.constructor?.name === "TableWidget") tableWidget = w;
    });
    expect(tableWidget).not.toBeNull();
    const segs = tableWidget.model.rows.flat(2); // rows → 行 → 单元格 → 片段，需两层展开
    const mathSeg = segs.find((s) => s.math);
    const hlSeg = segs.find((s) => s.hl);
    expect(mathSeg?.latex).toBe("a+b");
    expect(hlSeg?.text).toBe("重点");
    // 行内代码不受影响
    expect(segs.some((s) => s.marks.includes("c") && s.text === "code")).toBe(true);
  });

  it("mermaid：离块替换为 widget，wysiwyg 模式光标进入显露源码", () => {
    const fieldW = wysiwyg(false); // reading 模式永不显源码，光标交互用 wysiwyg 模式验证
    const stateW = EditorState.create({
      doc: DOC4,
      extensions: [markdown({ base: markdownLanguage }), fieldW],
    });
    const countWidget = (st) => {
      let c = 0;
      st.field(fieldW).between(0, 1e9, (_f, _t, v) => {
        if (v.isReplace && v.spec?.widget?.constructor?.name === "MermaidWidget") c++;
      });
      return c;
    };
    expect(countWidget(stateW)).toBe(2); // 合法与非法定义都先替换（渲染失败由 toDOM 降级）
    const mermaidLine = stateW.doc.line(15).from; // 第二个 mermaid 块内
    const s5 = stateW.update({ selection: { anchor: mermaidLine } }).state;
    expect(countWidget(s5)).toBe(1); // 光标所在块显露源码，另一个仍是图表
  });
});

// P2：图片尺寸语法、TOC 目录块
describe("P2 装饰：图片尺寸与 TOC 目录", () => {
  const DOC5 = [
    "# 主标题",
    "",
    "[TOC]",
    "",
    "## 第一节",
    "",
    "### 嵌套节",
    "",
    "![alt|300](a.png)",
    "",
    "![说明|320x240](b.png)",
    "",
    "![cap](c.png)",
    "",
    "[[TOC]]",
  ].join("\n");
  const field5 = wysiwyg(true);
  const state5 = EditorState.create({
    doc: DOC5,
    extensions: [markdown({ base: markdownLanguage }), field5],
  });

  const widgets = () => {
    const list = [];
    state5.field(field5).between(0, 1e9, (_f, _t, v) => {
      if (v.isReplace && v.spec?.widget) list.push(v.spec.widget);
    });
    return list;
  };

  it("图片尺寸：Obsidian |W / |WxH 解析入 widget，alt 剥离尺寸尾巴（Typora =WxH 带空格不符合 CommonMark，lezer 不解析为图片，不支持）", () => {
    const imgs = widgets().filter((w) => w.constructor?.name === "ImageWidget");
    expect(imgs).toHaveLength(3);
    expect(imgs[0].width).toBe(300);
    expect(imgs[0].height).toBeUndefined();
    expect(imgs[0].alt).toBe("alt");
    expect(imgs[1].width).toBe(320);
    expect(imgs[1].height).toBe(240);
    expect(imgs[1].alt).toBe("说明");
    expect(imgs[2].width).toBeUndefined(); // 无尺寸语法保持原尺寸
  });

  it("TOC：[TOC] 与 [[TOC]] 行都替换为目录块，标题层级完整", () => {
    const tocs = widgets().filter((w) => w.constructor?.name === "TocWidget");
    expect(tocs).toHaveLength(2);
    const levels = tocs[0].headings.map((h) => h.level);
    expect(levels).toEqual([1, 2, 3]);
    expect(tocs[0].headings[0].text).toBe("主标题");
  });

  it("光标进入 TOC 行 → 显露源码（widget 消失）", () => {
    const fieldW = wysiwyg(false);
    const stateW = EditorState.create({
      doc: DOC5,
      extensions: [markdown({ base: markdownLanguage }), fieldW],
    });
    const tocLine = 3;
    const active = stateW.update({ selection: { anchor: stateW.doc.line(tocLine).from } }).state;
    let count = 0;
    active.field(fieldW).between(0, 1e9, (_f, _t, v) => {
      if (v.isReplace && v.spec?.widget?.constructor?.name === "TocWidget") count++;
    });
    expect(count).toBe(1); // [[TOC]] 行仍是 widget，[TOC] 行显露
  });
});
