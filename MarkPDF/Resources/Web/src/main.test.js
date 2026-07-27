// @vitest-environment jsdom
// 编辑器内核入口（src/main.js）生命周期测试（B1 回归）：
// 内容变更经 300ms 防抖上报；pagehide / visibilitychange(→hidden) 时
// 挂起的 contentChanged 必须立即发出（切标签/关标签销毁 webView 不丢尾巴）。
import { describe, it, expect, vi, beforeAll } from "vitest";
import { setSearchQuery, SearchQuery } from "@codemirror/search";

// mock 桥接层：直接断言 notify 调用（bridge.js 的 console mock 无法区分消息类型断言）
vi.mock("./bridge.js", () => ({
  notify: vi.fn(),
  respond: vi.fn(),
  request: vi.fn(() => Promise.resolve({})),
  onMessage: vi.fn(),
}));

import * as Bridge from "./bridge.js";

let view;

beforeAll(async () => {
  // jsdom 无 ResizeObserver/rAF（视 vitest 版本而定），补齐后 CM6 才能挂载
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  globalThis.requestAnimationFrame ??= (cb) => setTimeout(() => cb(Date.now()), 0);
  globalThis.cancelAnimationFrame ??= (id) => clearTimeout(id);
  // jsdom 的 Range 未实现几何 API，CM6 测量层（drawSelection）会调用；补空实现消除噪声
  Range.prototype.getClientRects ??= () => [];
  Range.prototype.getBoundingClientRect ??= () => ({
    x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0,
  });
  document.body.innerHTML = '<div id="editor"></div>';
  await import("./main.js");
  view = window.__cmView;
  expect(view).toBeTruthy();
});

function contentChangedCalls() {
  return Bridge.notify.mock.calls.filter(([type]) => type === "editor.contentChanged");
}

describe("main.js 防抖窗口兜底（B1）", () => {
  it("visibilitychange → hidden：挂起的 contentChanged 立即发出", () => {
    Bridge.notify.mockClear();
    view.dispatch({ changes: { from: 0, insert: "尾巴一" } });
    // 防抖 300ms 未到，不应已上报
    expect(contentChangedCalls()).toHaveLength(0);

    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => "hidden",
    });
    document.dispatchEvent(new Event("visibilitychange"));

    const calls = contentChangedCalls();
    expect(calls).toHaveLength(1);
    expect(calls[0][1].text).toContain("尾巴一");
  });

  it("pagehide：挂起的 contentChanged 立即发出", () => {
    Bridge.notify.mockClear();
    view.dispatch({ changes: { from: 0, insert: "尾巴二" } });
    expect(contentChangedCalls()).toHaveLength(0);

    window.dispatchEvent(new Event("pagehide"));

    const calls = contentChangedCalls();
    expect(calls).toHaveLength(1);
    expect(calls[0][1].text).toContain("尾巴二");
  });

  it("无挂起变更时 pagehide 不发重复 contentChanged", () => {
    Bridge.notify.mockClear();
    window.dispatchEvent(new Event("pagehide"));
    expect(contentChangedCalls()).toHaveLength(0);
  });
});

// 批次四：editor.scrollToLine 对非整数/NaN/越界行号的防御（修复前 doc.line(0.5) 抛 RangeError）
describe("scrollToLine 行号防御", () => {
  const handler = () =>
    Bridge.onMessage.mock.calls.find(([type]) => type === "editor.scrollToLine")?.[1];

  beforeAll(() => {
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "一\n二\n三\n四\n五" } });
  });

  it("非整数/NaN/负数/越界：截尾取整后 clamp，不抛异常", () => {
    const h = handler();
    expect(h).toBeTruthy();
    expect(() => h({ line: 0.5 })).not.toThrow();
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(1);
    h({ line: NaN });
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(1);
    h({ line: 3.9 });
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(3);
    h({ line: 9999 });
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(5);
    h({ line: -5 });
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(1);
  });
});

// 批次四：查找面板 ↑↓ 步进到末/首命中后回绕（修复前越过末命中即停）
describe("查找面板 ↑↓ 回绕", () => {
  // 构造面板内目标元素并派发按键（监听器要求 target 在 .cm-search 内）
  function pressSearchArrow(key) {
    const panel = document.createElement("div");
    panel.className = "cm-search";
    const input = document.createElement("input");
    panel.append(input);
    view.dom.append(panel);
    input.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    panel.remove();
  }

  beforeAll(() => {
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "a x b x c" } });
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: "x" })) });
  });

  it("末命中后 ↓ 回绕到首个；首命中前 ↑ 回绕到末个", () => {
    // 文档 "a x b x c"：两个命中 [2,3] 与 [6,7]
    view.dispatch({ selection: { anchor: 6, head: 7 } });
    pressSearchArrow("ArrowDown");
    expect([view.state.selection.main.anchor, view.state.selection.main.head]).toEqual([2, 3]);

    pressSearchArrow("ArrowUp");
    expect([view.state.selection.main.anchor, view.state.selection.main.head]).toEqual([6, 7]);
  });

  it("中间命中正常步进（不触发回绕）", () => {
    view.dispatch({ selection: { anchor: 2, head: 3 } });
    pressSearchArrow("ArrowDown");
    expect([view.state.selection.main.anchor, view.state.selection.main.head]).toEqual([6, 7]);
  });
});

// 批次四：图片粘贴失败（桥超时/FileReader 错误）经 console.error 留诊断（修复前完全静默）
describe("图片粘贴失败上报", () => {
  it("桥请求 reject → console.error 留诊断信息", async () => {
    Bridge.request.mockRejectedValueOnce(new Error("bridge timeout: editor.saveImage"));
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const e = new Event("paste", { bubbles: true, cancelable: true });
      e.clipboardData = {
        items: [
          {
            kind: "file",
            type: "image/png",
            getAsFile: () => new File(["x"], "a.png", { type: "image/png" }),
          },
        ],
      };
      view.dom.dispatchEvent(e);
      await vi.waitFor(() => expect(errSpy).toHaveBeenCalled());
      expect(String(errSpy.mock.calls[0][1])).toContain("editor.saveImage");
    } finally {
      errSpy.mockRestore();
    }
  });
});

// FR-AI.2：AI 助手编辑器动作的桥消息
describe("AI 助手桥消息（getSelection / replaceSelection）", () => {
  const handler = (type) =>
    Bridge.onMessage.mock.calls.find(([t]) => t === type)?.[1];

  it("getSelection：有选区应答文本与区间", () => {
    Bridge.respond.mockClear();
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: "选中我这段文字" },
      selection: { anchor: 0 },
    });
    view.dispatch({ selection: { anchor: 2, head: 5 } });
    handler("editor.getSelection")({}, "req-1");
    expect(Bridge.respond).toHaveBeenCalledWith("req-1", { text: "我这段", from: 2, to: 5 });
  });

  it("getSelection：无选区应答空文本", () => {
    Bridge.respond.mockClear();
    view.dispatch({ selection: { anchor: 1 } });
    handler("editor.getSelection")({}, "req-2");
    expect(Bridge.respond).toHaveBeenCalledWith("req-2", { text: "", from: 1, to: 1 });
  });

  it("replaceSelection：空选区拒绝且文档不变", () => {
    Bridge.respond.mockClear();
    const before = view.state.doc.toString();
    view.dispatch({ selection: { anchor: 0 } });
    handler("editor.replaceSelection")({ text: "不该出现" }, "req-3");
    expect(Bridge.respond).toHaveBeenCalledWith("req-3", { replaced: false });
    expect(view.state.doc.toString()).toBe(before);
  });

  it("replaceSelection：非空选区替换成功", () => {
    Bridge.respond.mockClear();
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: "abcdef" },
      selection: { anchor: 0 },
    });
    view.dispatch({ selection: { anchor: 1, head: 4 } });
    handler("editor.replaceSelection")({ text: "XY" }, "req-4");
    expect(Bridge.respond).toHaveBeenCalledWith("req-4", { replaced: true });
    expect(view.state.doc.toString()).toBe("aXYef");
  });
});
