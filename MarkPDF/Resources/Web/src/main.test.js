// @vitest-environment jsdom
// 编辑器内核入口（src/main.js）生命周期测试（B1 回归）：
// 内容变更经 300ms 防抖上报；pagehide / visibilitychange(→hidden) 时
// 挂起的 contentChanged 必须立即发出（切标签/关标签销毁 webView 不丢尾巴）。
import { describe, it, expect, vi, beforeAll } from "vitest";

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
