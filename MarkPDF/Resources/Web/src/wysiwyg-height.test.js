// @vitest-environment jsdom
// 大尺寸 widget 高度估计（滚动抖动修复）：estimatedHeight 按内容估算、
// 高度缓存优先于估算、行内公式不参与 block 估计
import { describe, it, expect, afterEach } from "vitest";
import { MathWidget, TableWidget, ImageWidget, widgetHeightCache } from "./wysiwyg.js";

afterEach(() => widgetHeightCache.clear());

describe("MathWidget.estimatedHeight", () => {
  it("行内公式返回 -1（随文本行高，CM 默认处理）", () => {
    expect(new MathWidget("a+b", false, "$a+b$").estimatedHeight).toBe(-1);
  });

  it("块级单行公式按单行 display 估算", () => {
    const w = new MathWidget("\\int_0^1 x\\,dx", true, "$$\\int_0^1 x\\,dx$$");
    expect(w.estimatedHeight).toBe(44 + 16);
  });

  it("多行环境（\\\\ 换行）按行数累加", () => {
    const latex = "\\begin{aligned} a &= b \\\\ c &= d \\\\ e &= f \\end{aligned}";
    const w = new MathWidget(latex, true, `$$${latex}$$`);
    expect(w.estimatedHeight).toBe(3 * 44 + 16);
  });

  it("高度缓存优先于内容估算（滚动重建后估计与实测一致，不再跳变）", () => {
    const latex = "x^2+y^2";
    const source = `$$${latex}$$`;
    // 模拟浏览器实测写入（生产由 toDOM 后 rAF + offsetHeight 完成；jsdom offsetHeight=0）
    widgetHeightCache.set("m:" + source, 87);
    expect(new MathWidget(latex, true, source).estimatedHeight).toBe(87);
  });
});

describe("TableWidget.estimatedHeight", () => {
  const model = (rows) => ({
    header: [[{ text: "h", marks: [] }]],
    rows: rows.map(() => [[{ text: "c", marks: [] }]]),
    rowOffsets: [0, 10, 20, 30],
  });

  it("按行数估算（表头+数据行）", () => {
    expect(new TableWidget(model([1, 2, 3]), "src").estimatedHeight).toBe(4 * 38 + 16);
    expect(new TableWidget(model([]), "src").estimatedHeight).toBe(1 * 38 + 16);
  });
});

describe("ImageWidget", () => {
  it("img 加载完成后请求 CM 重测行高（异步撑高行的跳变修正）", () => {
    const w = new ImageWidget("markpdf-file:///a.png", "alt");
    let measured = 0;
    const view = { requestMeasure: () => measured++, dispatch() {}, posAtDOM: () => 0 };
    const el = w.toDOM(view);
    expect(el.tagName).toBe("IMG");
    el.onload();
    expect(measured).toBe(1);
  });
});
