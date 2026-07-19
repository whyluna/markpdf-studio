// MarkPDF Markdown 编辑器内核入口（FR-2.1 / FR-2.2 / FR-2.7）
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, placeholder, drawSelection } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { search, searchKeymap } from "@codemirror/search";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle, LanguageDescription, LanguageSupport, StreamLanguage, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

// 自定义高亮：代码块 token 配色走 CSS 变量（随明暗主题切换）；
// 显式取消 defaultHighlightStyle 给标题加的 underline
const mdHighlight = HighlightStyle.define([
  { tag: t.heading, textDecoration: "none", fontWeight: "600" },
  { tag: t.keyword, color: "var(--tok-k)" },
  { tag: [t.string, t.special(t.string)], color: "var(--tok-s)" },
  { tag: t.comment, color: "var(--tok-c)", fontStyle: "italic" },
  { tag: [t.function(t.variableName), t.propertyName, t.typeName], color: "var(--tok-f)" },
  { tag: [t.number, t.atom, t.bool], color: "var(--tok-n)" },
  { tag: t.link, textDecoration: "none" },
]);
import { python } from "@codemirror/lang-python";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { yaml } from "@codemirror/lang-yaml";
import { cpp } from "@codemirror/lang-cpp";
import { java } from "@codemirror/lang-java";
import { rust } from "@codemirror/lang-rust";
import { sql } from "@codemirror/lang-sql";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { go } from "@codemirror/legacy-modes/mode/go";
import { swift } from "@codemirror/legacy-modes/mode/swift";

// 代码块语法高亮语言白名单（控制内核体积，全量包约 1.5MB → 子集 ~500KB）
const codeLanguages = [
  LanguageDescription.of({ name: "python", alias: ["py"], support: python() }),
  LanguageDescription.of({ name: "javascript", alias: ["js", "jsx"], support: javascript() }),
  LanguageDescription.of({ name: "typescript", alias: ["ts", "tsx"], support: javascript({ typescript: true }) }),
  LanguageDescription.of({ name: "json", support: json() }),
  LanguageDescription.of({ name: "yaml", alias: ["yml"], support: yaml() }),
  // 注意：support 必须是 LanguageSupport（lang-markdown 取 support.language.parser），
  // StreamLanguage 需显式包裹，否则解析该语言代码块时崩溃
  LanguageDescription.of({ name: "bash", alias: ["sh", "shell", "zsh"], support: new LanguageSupport(StreamLanguage.define(shell)) }),
  LanguageDescription.of({ name: "c", support: cpp() }),
  LanguageDescription.of({ name: "cpp", alias: ["c++"], support: cpp() }),
  LanguageDescription.of({ name: "java", support: java() }),
  LanguageDescription.of({ name: "rust", alias: ["rs"], support: rust() }),
  LanguageDescription.of({ name: "go", alias: ["golang"], support: new LanguageSupport(StreamLanguage.define(go)) }),
  LanguageDescription.of({ name: "swift", support: new LanguageSupport(StreamLanguage.define(swift)) }),
  LanguageDescription.of({ name: "sql", support: sql() }),
  LanguageDescription.of({ name: "html", support: html() }),
  LanguageDescription.of({ name: "css", support: css() }),
];
import { wysiwyg } from "./wysiwyg.js";
import * as Bridge from "./bridge.js";
import { DEMO_DOC } from "./demo.js";
import { docContext } from "./doccontext.js";

/* ---------- 模式（FR-2.2） ---------- */

const modeConf = new Compartment();

function modeExtension(mode) {
  if (mode === "source") {
    return [EditorView.editable.of(true), EditorState.readOnly.of(false)];
  }
  if (mode === "reading") {
    return [EditorView.editable.of(false), EditorState.readOnly.of(true), wysiwyg(true)];
  }
  // wysiwyg（默认）
  return [EditorView.editable.of(true), EditorState.readOnly.of(false), wysiwyg(false)];
}

/* ---------- 基础主题（颜色全部走 CSS 变量，由外壳控制明暗） ---------- */

const baseTheme = EditorView.theme({
  "&": { backgroundColor: "var(--win-bg)", color: "var(--text)", height: "100%" },
  ".cm-scroller": { fontFamily: "var(--editor-font)", overflow: "auto" },
  ".cm-content": {
    maxWidth: "780px",
    margin: "0 auto",
    padding: "38px 52px 140px",
    fontSize: "15.5px",
    lineHeight: "1.8",
    caretColor: "var(--accent)",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor": { borderLeft: "2px solid var(--accent)" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    backgroundColor: "var(--sel) !important",
  },
  ".cm-placeholder": { color: "var(--text3)" },
});

/* ---------- 编辑器实例 ---------- */

const view = new EditorView({
  parent: document.getElementById("editor"),
  state: EditorState.create({
    doc: DEMO_DOC,
    extensions: [
      history(),
      // 自绘光标/选区：替代 WebKit 原生光标（原生按 line-height 1.8 的行框绘制，显得过长）
      drawSelection(),
      search({ top: true }),
      keymap.of([...searchKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
      markdown({ base: markdownLanguage, codeLanguages }),
      syntaxHighlighting(mdHighlight),
      baseTheme,
      EditorView.lineWrapping,
      placeholder("开始输入 Markdown…"),
      modeConf.of(modeExtension("wysiwyg")),
      EditorView.updateListener.of((u) => {
        if (u.docChanged) scheduleContentNotify();
        if (u.selectionSet || u.docChanged) scheduleCursorNotify();
      }),
    ],
  }),
});

/* ---------- 内容变更通知（防抖 300ms，native 侧据此落盘 FR-2.7） ---------- */

let notifyTimer = null;
function scheduleContentNotify() {
  clearTimeout(notifyTimer);
  notifyTimer = setTimeout(() => {
    Bridge.notify("editor.contentChanged", { text: view.state.doc.toString() });
    Bridge.notify("editor.outline", { items: collectOutline() });
  }, 300);
}

/* ---------- 光标行上报（防抖 500ms，FR-1.6 编辑位置记忆） ---------- */

let cursorTimer = null;
function scheduleCursorNotify() {
  clearTimeout(cursorTimer);
  cursorTimer = setTimeout(() => {
    const line = view.state.doc.lineAt(view.state.selection.main.head).number;
    Bridge.notify("editor.cursor", { line });
  }, 500);
}

/* ---------- 大纲提取（FR-2.6）：ATX / Setext 标题 → { level, text, line } ---------- */

function collectOutline() {
  const items = [];
  syntaxTree(view.state).iterate({
    enter(node) {
      const m = /^(?:ATXHeading([1-6])|SetextHeading([12]))$/.exec(node.name);
      if (!m) return;
      const level = m[1] ? Number(m[1]) : Number(m[2]);
      const line = view.state.doc.lineAt(node.from);
      const text = line.text.replace(/^#{1,6}\s*/, "").trim();
      if (text) items.push({ level, text, line: line.number });
      return false;
    },
  });
  return items;
}

/* ---------- native → web 消息注册 ---------- */

Bridge.onMessage("editor.setContent", (p) => {
  // 记录文档基准目录（md 文件所在目录），供图片相对路径解析（FR-2.3）
  docContext.baseURL = p.baseURL ?? null;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: p.text ?? "" },
  });
  // FR-1.6：载入即恢复上次编辑位置（不抢焦点）
  if (typeof p.initialLine === "number") scrollToLine(p.initialLine, false);
});

Bridge.onMessage("editor.getContent", (_p, id) => {
  Bridge.respond(id, { text: view.state.doc.toString() });
});

Bridge.onMessage("editor.setMode", (p) => {
  const mode = ["wysiwyg", "source", "reading"].includes(p.mode) ? p.mode : "wysiwyg";
  view.dispatch({ effects: modeConf.reconfigure(modeExtension(mode)) });
});

Bridge.onMessage("editor.setTheme", (p) => {
  document.documentElement.dataset.theme = p.theme === "dark" ? "dark" : "light";
});

Bridge.onMessage("editor.insertAtCursor", (p) => {
  view.dispatch(view.state.replaceSelection(p.text ?? ""));
});

// 大纲跳转（FR-2.6）：滚动到指定行并落光标
function scrollToLine(line, focus = true) {
  const clamped = Math.max(1, Math.min(line ?? 1, view.state.doc.lines));
  const pos = view.state.doc.line(clamped).from;
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: "start" }),
  });
  if (focus) view.focus();
}
Bridge.onMessage("editor.scrollToLine", (p) => scrollToLine(p.line));

/* ---------- ⌘+点击链接跳转（FR-2.3 链接交互） ---------- */

// 按住 ⌘ 时链接显示手型与下划线
window.addEventListener("keydown", (e) => {
  if (e.metaKey) view.dom.classList.add("cm-mod-down");
});
window.addEventListener("keyup", (e) => {
  if (!e.metaKey) view.dom.classList.remove("cm-mod-down");
});
window.addEventListener("blur", () => view.dom.classList.remove("cm-mod-down"));

// 从语法树提取覆盖 pos 的 Link 节点的 URL
function findLinkURLAt(pos) {
  let url = null;
  syntaxTree(view.state).iterate({
    enter(node) {
      if (url || node.name !== "Link" || node.from > pos || node.to < pos) return;
      for (let c = node.node.firstChild; c; c = c.nextSibling) {
        if (c.name === "URL") url = view.state.doc.sliceString(c.from, c.to);
      }
      return false;
    },
  });
  return url;
}

// capture 阶段拦截 ⌘+mousedown：先于 CM 的落光标逻辑，链接不展开直接跳转
view.dom.addEventListener(
  "mousedown",
  (e) => {
    if (!e.metaKey) return;
    const linkEl = e.target.closest(".cm-link");
    if (!linkEl) return;
    e.preventDefault();
    e.stopPropagation();
    const url = findLinkURLAt(view.posAtDOM(linkEl));
    if (url) Bridge.notify("editor.openLink", { url });
  },
  true
);

/* ---------- 图片粘贴/拖拽入 assets（FR-2.5） ---------- */

// 图片二进制 → native 存盘（请求-响应，应答 {path} 或 {error}）
function sendImageToNative(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = String(reader.result).split(",")[1] ?? "";
      Bridge.request("editor.saveImage", {
        name: file.name || "",
        mime: file.type || "",
        data: base64,
      }).then(resolve, reject);
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

function insertImageLink(path) {
  view.dispatch(view.state.replaceSelection(`![](${path})`));
  view.focus();
}

function handleImageFile(file) {
  if (!file) return;
  sendImageToNative(file)
    .then((p) => {
      if (p && p.path) insertImageLink(p.path);
      // 失败（{error}）时 native 已弹提示，此处静默
    })
    .catch(() => {});
}

// 粘贴：剪贴板含图片时接管，否则交给 CM 默认文本粘贴
view.dom.addEventListener(
  "paste",
  (e) => {
    const items = [...(e.clipboardData?.items ?? [])];
    const imgItem = items.find((it) => it.kind === "file" && it.type.startsWith("image/"));
    if (!imgItem) return;
    e.preventDefault();
    e.stopPropagation();
    handleImageFile(imgItem.getAsFile());
  },
  true
);

// 拖拽：图片文件落在编辑器内，落点处插入链接
view.dom.addEventListener(
  "drop",
  (e) => {
    const files = [...(e.dataTransfer?.files ?? [])].filter((f) => f.type.startsWith("image/"));
    if (!files.length) return;
    e.preventDefault();
    e.stopPropagation();
    const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
    if (pos != null) view.dispatch({ selection: { anchor: pos } });
    files.forEach(handleImageFile);
  },
  true
);
view.dom.addEventListener("dragover", (e) => {
  const hasImage = [...(e.dataTransfer?.items ?? [])].some((it) => it.type.startsWith("image/"));
  if (hasImage) e.preventDefault();
});

Bridge.notify("editor.ready", { version: "0.1.0" });

// 调试句柄：供 native 探针/浏览器控制台诊断坐标映射（不影响功能）
window.__cmView = view;
