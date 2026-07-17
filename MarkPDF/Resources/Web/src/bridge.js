// MarkPDF WebBridge · Swift ↔ Web 类型化消息协议（开发规范 §3.4）
// 信封格式：{ id?: string, type: string, payload: object }
// native → web：Swift 侧 evaluateJavaScript 调用 window.bridge.receive(envelope)
// web → native：window.webkit.messageHandlers.bridge.postMessage(envelope)
// 浏览器开发环境下自动降级为 console mock，保证内核可独立调试

const handlers = new Map();
const pending = new Map();
let seq = 0;

const isNative = !!(
  window.webkit &&
  window.webkit.messageHandlers &&
  window.webkit.messageHandlers.bridge
);

function send(envelope) {
  if (isNative) {
    window.webkit.messageHandlers.bridge.postMessage(envelope);
  } else {
    console.log("[bridge → native]", envelope);
    // mock：带 id 的请求自动回 ack，便于浏览器内联调
    if (envelope.id) {
      setTimeout(
        () => receive({ id: envelope.id, type: "bridge.response", payload: { ok: true, mock: true } }),
        0
      );
    }
  }
}

/** 注册 native → web 的消息处理器 */
export function onMessage(type, handler) {
  handlers.set(type, handler);
}

/** web → native 单向通知 */
export function notify(type, payload = {}) {
  send({ type, payload });
}

/** 应答 native 发来的带 id 请求 */
export function respond(id, payload = {}) {
  if (id) send({ id, type: "bridge.response", payload });
}

/** web → native 请求-响应（3s 超时） */
export function request(type, payload = {}) {
  const id = "req-" + Date.now() + "-" + ++seq;
  send({ id, type, payload });
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    setTimeout(() => {
      if (pending.delete(id)) reject(new Error("bridge timeout: " + type));
    }, 3000);
  });
}

function receive(envelope) {
  if (!envelope || typeof envelope.type !== "string") return;
  if (envelope.id && pending.has(envelope.id)) {
    pending.get(envelope.id)(envelope.payload);
    pending.delete(envelope.id);
    return;
  }
  const handler = handlers.get(envelope.type);
  if (handler) handler(envelope.payload ?? {}, envelope.id);
  else console.warn("[bridge] 未注册的消息类型:", envelope.type);
}

window.bridge = { receive, notify, request };
export { receive };
