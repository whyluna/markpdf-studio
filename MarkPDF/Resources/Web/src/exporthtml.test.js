// @vitest-environment jsdom
// 导出 HTML 纯函数单测（FR-2.9）：标题提取、图片重写、HTML 包装
import { describe, it, expect } from "vitest";
import { extractTitle, rewriteImgSrc, buildExportHTML } from "./exporthtml.js";

describe("extractTitle", () => {
  it("取第一个 ATX 标题并去行内标记", () => {
    expect(extractTitle("# **KV Cache** 调研\n正文")).toBe("KV Cache 调研");
    expect(extractTitle("前文\n## 第二节 [链接](http://x)\n")).toBe("第二节 链接");
  });
  it("Setext 标题", () => {
    expect(extractTitle("调研笔记\n====\n正文")).toBe("调研笔记");
  });
  it("跳过代码块内的 # 注释", () => {
    expect(extractTitle("```\n# 不是标题\n```\n# 真标题\n")).toBe("真标题");
  });
  it("无标题回退默认名", () => {
    expect(extractTitle("只有正文")).toBe("Markdown 导出");
  });
  it("闭合 # 序列须前导空格（CommonMark）：# C# 的 # 属标题文本", () => {
    expect(extractTitle("# C#\n")).toBe("C#");
    expect(extractTitle("# C# 笔记\n")).toBe("C# 笔记");
    // 合法闭合序列照常剥离
    expect(extractTitle("# 标题 ##\n")).toBe("标题");
    expect(extractTitle("# 标题 #  \n")).toBe("标题");
  });
});

describe("rewriteImgSrc", () => {
  const base = "file:///Users/w/ws/notes/";
  it("markpdf-file 在 baseURL 内 → 相对路径", () => {
    expect(rewriteImgSrc("markpdf-file://host/Users/w/ws/notes/assets/a.png", base)).toBe("assets/a.png");
  });
  it("markpdf-file 在 baseURL 外 → file:// 绝对形式", () => {
    expect(rewriteImgSrc("markpdf-file://host/Users/w/other/x.png", base)).toBe("file:///Users/w/other/x.png");
  });
  it("相对路径 / http / data 原样保留", () => {
    expect(rewriteImgSrc("assets/a.png", base)).toBe("assets/a.png");
    expect(rewriteImgSrc("https://x.com/a.png", base)).toBe("https://x.com/a.png");
    expect(rewriteImgSrc("data:image/png;base64,xx", base)).toBe("data:image/png;base64,xx");
  });
  it("无 baseURL 时 markpdf-file → file:// 绝对形式", () => {
    expect(rewriteImgSrc("markpdf-file://host/abs/a.png", null)).toBe("file:///abs/a.png");
  });
});

describe("buildExportHTML", () => {
  it("包装为带主题/样式/外壳的独立文档", () => {
    const html = buildExportHTML({
      title: "笔记",
      theme: "dark",
      inlineStyles: [":root{--bg:#000}"],
      cssHrefs: ["file:///app/dist/editor.css"],
      contentHTML: "<p>正文</p>",
    });
    expect(html).toContain('data-theme="dark"');
    expect(html).toContain("<title>笔记</title>");
    expect(html).toContain(":root{--bg:#000}");
    expect(html).toContain('href="file:///app/dist/editor.css"');
    expect(html).toContain('<div class="cm-content">');
    expect(html).toContain("<p>正文</p>");
  });
  it("标题/href 转义", () => {
    const html = buildExportHTML({
      title: "a<b>&c",
      theme: "light",
      inlineStyles: [],
      cssHrefs: [],
      contentHTML: "",
    });
    expect(html).toContain("<title>a&lt;b&gt;&amp;c</title>");
  });
  it("双引号转义（属性插值安全）：title/theme/class/href 全覆盖", () => {
    const html = buildExportHTML({
      title: '他说"你好"',
      theme: 'dark"onload="x',
      inlineStyles: [],
      cssHrefs: ['file:///a"b/editor.css'],
      contentHTML: "",
      classes: { content: 'cm-content"evil' },
    });
    expect(html).toContain("<title>他说&quot;你好&quot;</title>");
    expect(html).toContain('data-theme="dark&quot;onload=&quot;x"');
    expect(html).toContain('href="file:///a&quot;b/editor.css"');
    expect(html).toContain('<div class="cm-content&quot;evil">');
    // 裸双引号不得出现在属性插值结果中
    expect(html).not.toContain('class="cm-content"evil"');
  });
});
