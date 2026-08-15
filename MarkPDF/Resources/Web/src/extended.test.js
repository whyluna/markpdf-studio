// 扩展语法扫描（src/extended.js）单元测试
import { describe, it, expect } from "vitest";
import { scanMath, scanHighlights, scanFootnotes, scanExtended } from "./extended.js";

describe("行内公式 $...$", () => {
  it("基本匹配", () => {
    const ms = scanMath("欧拉公式 $e^{i\\pi}+1=0$ 优美");
    expect(ms).toHaveLength(1);
    expect(ms[0].displayMode).toBe(false);
    expect(ms[0].latex).toBe("e^{i\\pi}+1=0");
    expect("欧拉公式 $e^{i\\pi}+1=0$ 优美".slice(ms[0].from, ms[0].to)).toBe("$e^{i\\pi}+1=0$");
  });

  it("一行多个公式", () => {
    const ms = scanMath("$a$ 和 $b$");
    expect(ms.map((m) => m.latex)).toEqual(["a", "b"]);
  });

  it("开 $ 后紧跟空格 → 拒绝", () => {
    expect(scanMath("价格 $ x$ 待定")).toHaveLength(0);
  });

  it("闭 $ 前是空格 → 拒绝", () => {
    expect(scanMath("价格 $x $ 待定")).toHaveLength(0);
  });

  it("空内容 $$ 单行两两配对成块级，$ $ 不匹配", () => {
    expect(scanMath("$ $")).toHaveLength(0);
  });

  it("货币不误判：$5 和 $5 / $5,$5", () => {
    expect(scanMath("苹果 $5 和 $5 元")).toHaveLength(0);
    expect(scanMath("共 $5,$5 两件")).toHaveLength(0);
    expect(scanMath("$5 and $5")).toHaveLength(0);
  });

  it("不跨行", () => {
    expect(scanMath("$a\nb$")).toHaveLength(0);
  });

  it("转义 \\$ 不作开标记", () => {
    expect(scanMath("\\$x$")).toHaveLength(0);
  });
});

describe("块级公式 $$...$$", () => {
  it("多行块级", () => {
    const text = "前\n$$\na+b=c\n$$\n后";
    const ms = scanMath(text);
    expect(ms).toHaveLength(1);
    expect(ms[0].displayMode).toBe(true);
    expect(ms[0].latex).toBe("\na+b=c\n");
    expect(text.slice(ms[0].from, ms[0].to)).toBe("$$\na+b=c\n$$");
  });

  it("单行 $$x$$ 也算块级", () => {
    const ms = scanMath("$$E=mc^2$$");
    expect(ms).toHaveLength(1);
    expect(ms[0].displayMode).toBe(true);
    expect(ms[0].latex).toBe("E=mc^2");
  });

  it("$$ 优先于行内 $", () => {
    // $$a$$ 整体一个块级，而不是两个空行内
    const ms = scanMath("$$a$$");
    expect(ms).toHaveLength(1);
    expect(ms[0].displayMode).toBe(true);
  });

  it("块级内容允许包含单个 $", () => {
    const ms = scanMath("$$a $ b$$");
    expect(ms).toHaveLength(1);
    expect(ms[0].latex).toBe("a $ b");
  });

  it("空块级 $$$$ 不匹配", () => {
    expect(scanMath("$$$$")).toHaveLength(0);
  });
});

describe("代码区排除", () => {
  it("行内代码与代码块内的公式/高亮/脚注不生效", () => {
    const text = "`$x$ ==y== [^a]` 外 $z$";
    // 模拟语法树给出的行内代码范围
    const code = [{ from: 0, to: 18 }];
    const r = scanExtended(text, code);
    expect(r.maths.map((m) => m.latex)).toEqual(["z"]);
    expect(r.highlights).toHaveLength(0);
    expect(r.footnoteRefs).toHaveLength(0);
  });

  it("跨越代码区边界的公式不匹配", () => {
    const text = "$a `code $` b$";
    const code = [{ from: 3, to: 12 }];
    expect(scanMath(text, code)).toHaveLength(0);
  });
});

describe("高亮 ==x==", () => {
  it("基本匹配与范围划分", () => {
    const text = "这是 ==重要== 内容";
    const hs = scanHighlights(text);
    expect(hs).toHaveLength(1);
    const h = hs[0];
    expect(text.slice(h.openFrom, h.openTo)).toBe("==");
    expect(text.slice(h.contentFrom, h.contentTo)).toBe("重要");
    expect(text.slice(h.closeFrom, h.closeTo)).toBe("==");
  });

  it("相邻两组", () => {
    const hs = scanHighlights("==a==b==c==");
    expect(hs).toHaveLength(2);
    expect("==a==b==c==".slice(hs[0].contentFrom, hs[0].contentTo)).toBe("a");
    expect("==a==b==c==".slice(hs[1].contentFrom, hs[1].contentTo)).toBe("c");
  });

  it("嵌套边界：==a ==b== c== 只匹配最内层", () => {
    const text = "==a ==b== c==";
    const hs = scanHighlights(text);
    expect(hs).toHaveLength(1);
    expect(text.slice(hs[0].from, hs[0].to)).toBe("==b==");
  });

  it("标记内侧带空格 → 拒绝", () => {
    expect(scanHighlights("== 空格==")).toHaveLength(0);
    expect(scanHighlights("==空格 ==")).toHaveLength(0);
  });

  it("==== 与 ===x=== 不匹配", () => {
    expect(scanHighlights("====")).toHaveLength(0);
    expect(scanHighlights("===x===")).toHaveLength(0);
  });

  it("不跨行", () => {
    expect(scanHighlights("==a\nb==")).toHaveLength(0);
  });

  it("内容允许包含单个 = 与公式", () => {
    expect(scanHighlights("==a=b==")).toHaveLength(1);
    const r = scanExtended("==$x$==");
    expect(r.highlights).toHaveLength(1);
    expect(r.maths).toHaveLength(1);
  });
});

describe("脚注", () => {
  it("引用编号按首次引用顺序分配", () => {
    const { refs } = scanFootnotes("[^b] 和 [^a] 再 [^b]");
    expect(refs.map((r) => [r.label, r.n])).toEqual([
      ["b", 1],
      ["a", 2],
      ["b", 1],
    ]);
  });

  it("定义行识别：标记范围含尾随空格，内容不计引用", () => {
    const text = "[^a]: 脚注内容";
    const { refs, defs } = scanFootnotes(text);
    expect(defs).toHaveLength(1);
    expect(defs[0].label).toBe("a");
    expect(text.slice(defs[0].markerFrom, defs[0].markerTo)).toBe("[^a]: ");
    // 定义标记本身不算一次引用
    expect(refs).toHaveLength(0);
  });

  it("引用与定义共存：引用编号不受定义行影响", () => {
    const text = "见 [^a] 与 [^b]\n\n[^a]: 注释\n[^b]: 注释";
    const { refs, defs } = scanFootnotes(text);
    expect(refs.map((r) => r.n)).toEqual([1, 2]);
    expect(defs).toHaveLength(2);
  });

  it("图片 alt 不算引用：![^a](x.png)", () => {
    const { refs } = scanFootnotes("![^a](x.png)");
    expect(refs).toHaveLength(0);
  });

  it("带目标的写法 [^a](x) 按链接处理：footnoteExcludes 排除后不生成引用（批次四）", () => {
    // lezer 将 [^注](2024) 整体解析为 Link；footnoteExcludes 由语法树 Link（含 URL）范围供给
    const text = "[^注](2024) 与 [^a]";
    const r = scanExtended(text, [], [{ from: 0, to: 10 }]);
    expect(r.footnoteRefs.map((x) => x.label)).toEqual(["a"]);
    // 对照：不传入排除时前缀会被误扫为引用（修复前行为）
    expect(scanExtended(text).footnoteRefs).toHaveLength(2);
  });

  it("非行首的 [^a]: 不是定义", () => {
    const { defs } = scanFootnotes("文字 [^a]: 并非定义");
    expect(defs).toHaveLength(0);
  });

  it("定义标记在代码块内 → 不识别", () => {
    const text = "[^a]: 内容";
    const { defs } = scanFootnotes(text, [{ from: 0, to: text.length }]);
    expect(defs).toHaveLength(0);
  });
});

describe("组合扫描 scanExtended", () => {
  it("公式内的 == 与 [^a] 不算数", () => {
    const text = "$$==x==$$ 与 $[^a]$";
    const r = scanExtended(text);
    expect(r.maths).toHaveLength(2);
    expect(r.highlights).toHaveLength(0);
    expect(r.footnoteRefs).toHaveLength(0);
  });

  it("三种语法共存各得其所", () => {
    const text = "公式 $x$、高亮 ==y==、脚注 [^a]\n\n[^a]: 注";
    const r = scanExtended(text);
    expect(r.maths).toHaveLength(1);
    expect(r.highlights).toHaveLength(1);
    expect(r.footnoteRefs).toHaveLength(1);
    expect(r.footnoteRefs[0].n).toBe(1);
    expect(r.footnoteDefs).toHaveLength(1);
  });
});

describe("标题锚点匹配（目录跳转）", () => {
  const headings = [
    { level: 2, text: "KIVI：非对称均匀量化", line: 10 },
    { level: 3, text: "3.1.1 PagedAttention (vLLM)", line: 20 },
    { level: 2, text: "结论与推荐路线", line: 30 },
  ];
  it("GitHub slug 匹配", async () => {
    const { matchHeadingLine } = await import("./extended.js");
    expect(matchHeadingLine("kivi非对称均匀量化", headings)).toBe(10);
    expect(matchHeadingLine("311-pagedattention-vllm", headings)).toBe(20);
    expect(matchHeadingLine("结论与推荐路线", headings)).toBe(30);
  });
  it("percent-encoded 锚点", async () => {
    const { matchHeadingLine } = await import("./extended.js");
    expect(matchHeadingLine(encodeURIComponent("结论与推荐路线"), headings)).toBe(30);
  });
  it("未命中返回 null", async () => {
    const { matchHeadingLine } = await import("./extended.js");
    expect(matchHeadingLine("不存在的标题", headings)).toBeNull();
  });
  it("slugifyHeading 规则", async () => {
    const { slugifyHeading } = await import("./extended.js");
    expect(slugifyHeading("3.1.1 PagedAttention (vLLM)")).toBe("311-pagedattention-vllm");
    expect(slugifyHeading("KIVI：非对称均匀量化")).toBe("kivi非对称均匀量化");
    expect(slugifyHeading("实验模型选择（A40 40GB）")).toBe("实验模型选择a40-40gb");
  });
  it("slugifyHeading 与 GitHub 一致：逐空格转连字符（不折叠）", async () => {
    const { slugifyHeading } = await import("./extended.js");
    expect(slugifyHeading("a  b")).toBe("a--b");
  });
  it("重复标题的 -1/-2 后缀锚点（GitHub 口径）", async () => {
    const { matchHeadingLine } = await import("./extended.js");
    const dup = [
      { level: 2, text: "概述", line: 10 },
      { level: 2, text: "方法", line: 20 },
      { level: 2, text: "概述", line: 30 },
      { level: 2, text: "概述", line: 40 },
    ];
    expect(matchHeadingLine("概述", dup)).toBe(10, "首个无后缀");
    expect(matchHeadingLine("概述-1", dup)).toBe(30, "第二个重复标题带 -1");
    expect(matchHeadingLine("概述-2", dup)).toBe(40, "第三个重复标题带 -2");
  });
});
