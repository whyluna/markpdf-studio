// MarkPDF Markdown 编辑器内核入口（FR-2.1 / FR-2.2 / FR-2.7）
import { EditorState, Compartment, StateField } from "@codemirror/state";
import { EditorView, keymap, placeholder, drawSelection, Decoration } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { search, searchKeymap, getSearchQuery } from "@codemirror/search";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle, LanguageDescription, LanguageSupport, StreamLanguage, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
// KaTeX 样式：esbuild 自动拆出 dist/editor.css 并复制字体（FR-2.4，离线打包不用 CDN）
import "katex/dist/katex.min.css";

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
import { buildExport } from "./exporthtml.js";
import { matchHeadingLine } from "./extended.js";

/* ---------- 模式（FR-2.2） ---------- */

const modeConf = new Compartment();

// 打字机/专注模式（FR-2.10）：默认关，native 推送开关
const typewriterConf = new Compartment();
const focusConf = new Compartment();

// 打字机模式：选区变化后当前行垂直居中（异步派发，避免 updateListener 内同步 dispatch）
const typewriterExt = EditorView.updateListener.of((u) => {
  if (!u.selectionSet) return;
  const head = u.state.selection.main.head;
  setTimeout(() => {
    view.dispatch({ effects: EditorView.scrollIntoView(head, { y: "center" }) });
  }, 0);
});

// 专注模式：当前行加 cm-focus-line 类，CSS 压暗其余行
const focusLineField = StateField.define({
  create(state) {
    return focusDecorations(state);
  },
  update(_deco, tr) {
    return focusDecorations(tr.state);
  },
  provide: (f) => EditorView.decorations.from(f),
});

function focusDecorations(state) {
  const line = state.doc.lineAt(state.selection.main.head);
  return Decoration.set([Decoration.line({ class: "cm-focus-line" }).range(line.from)]);
}

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
    // 字号/行高走 CSS 变量（FR-7.2 设置即时生效），回退值与 SettingsStore 默认一致
    fontSize: "var(--editor-font-size, 15.5px)",
    lineHeight: "var(--editor-line-height, 1.8)",
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

// 基础扩展：主实例与导出实例（FR-2.9 离屏渲染）共用，避免配置漂移
function baseExtensions() {
  return [
    markdown({ base: markdownLanguage, codeLanguages }),
    syntaxHighlighting(mdHighlight),
    baseTheme,
    EditorView.lineWrapping,
  ];
}

const view = new EditorView({
  parent: document.getElementById("editor"),
  state: EditorState.create({
    // App 内初始为空（防 setContent 丢失时误显示 demo 内容）；浏览器调试才用示例文档
    doc: new URLSearchParams(location.search).has("app") ? "" : DEMO_DOC,
    extensions: [
      history(),
      // 自绘光标/选区：替代 WebKit 原生光标（原生按 line-height 1.8 的行框绘制，显得过长）
      drawSelection(),
      search({ top: true }),
      keymap.of([...searchKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
      ...baseExtensions(),
      placeholder("开始输入 Markdown…"),
      modeConf.of(modeExtension("wysiwyg")),
      // 打字机/专注模式（FR-2.10）：默认关，经 editor.setTypewriter/setFocusMode 重配置
      typewriterConf.of([]),
      focusConf.of([]),
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

// 编辑器排版（FR-7.2）：字体/字号/行高 → CSS 变量，即时生效
Bridge.onMessage("editor.setTypography", (p) => {
  const style = document.documentElement.style;
  if (typeof p.fontSize === "number") style.setProperty("--editor-font-size", `${p.fontSize}px`);
  if (typeof p.lineHeight === "number") style.setProperty("--editor-line-height", String(p.lineHeight));
  // fontCSS 为空串时移除变量，回退到样式表默认字体栈
  if (typeof p.fontCSS === "string") style.setProperty("--editor-font", p.fontCSS);
});

// 打字机模式（FR-2.10）：选区变化后当前行垂直居中；开启时立即居中一次（即时反馈）
Bridge.onMessage("editor.setTypewriter", (p) => {
  const on = !!p.enabled;
  view.dispatch({ effects: typewriterConf.reconfigure(on ? typewriterExt : []) });
  if (on) {
    view.dispatch({
      effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: "center" }),
    });
  }
});

// 专注模式（FR-2.10）：压暗非当前行。
// 注意：开关类必须挂在 documentElement 上——CM 每次交易都会按主题重建 view.dom.className，
// 手动挂在编辑器根上的类会在下一次点击/输入时被抹掉（真机踩坑）
Bridge.onMessage("editor.setFocusMode", (p) => {
  const on = !!p.enabled;
  document.documentElement.classList.toggle("cm-focus-mode", on);
  view.dispatch({ effects: focusConf.reconfigure(on ? focusLineField : []) });
});

Bridge.onMessage("editor.insertAtCursor", (p) => {
  view.dispatch(view.state.replaceSelection(p.text ?? ""));
});

// 导出独立 HTML（FR-2.9）：阅读模式离屏重渲染，应答 {title, html}
Bridge.onMessage("editor.exportHTML", (_p, id) => {
  buildExport({
    docText: view.state.doc.toString(),
    baseURL: docContext.baseURL,
    extensions: [...baseExtensions(), ...modeExtension("reading")],
    theme: document.documentElement.dataset.theme === "dark" ? "dark" : "light",
  })
    .then(({ title, html }) => Bridge.respond(id, { title, html }))
    .catch(() => Bridge.respond(id, { error: "export render failed" }));
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

// 按住 ⌘ 时链接显示手型与下划线（挂 documentElement：view.dom.className 会被 CM 重建）
window.addEventListener("keydown", (e) => {
  if (e.metaKey) document.documentElement.classList.add("cm-mod-down");
});
window.addEventListener("keyup", (e) => {
  if (!e.metaKey) document.documentElement.classList.remove("cm-mod-down");
});
window.addEventListener("blur", () => document.documentElement.classList.remove("cm-mod-down"));

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

// ⌘F 查找面板：↑↓ 在面板内导航上一个/下一个命中（捕获阶段且限面板内目标，不影响正文光标）。
// 不走 findNext/findPrevious：其末尾 selectSearchInput 重聚焦会触发 DOM 选区同步竞态、
// 把刚派发的命中选区吞掉（首个 ↓ 空跳）；直接按查询游标派发选区
function stepSearchMatch(backward) {
  const query = getSearchQuery(view.state);
  if (!query.valid) return;
  const main = view.state.selection.main;
  // SearchQuery 是规格对象，nextMatch/prevMatch 在其 create() 的 QueryType 上
  const qt = query.create();
  const match = backward
    ? qt.prevMatch(view.state, main.from, main.from)
    : qt.nextMatch(view.state, main.to, main.to);
  if (!match) return;
  view.dispatch({
    selection: { anchor: match.from, head: match.to },
    effects: EditorView.scrollIntoView(match.from, { y: "center" }),
    userEvent: "select.search",
  });
}
view.dom.addEventListener(
  "keydown",
  (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const target = e.target;
    if (!(target instanceof HTMLElement) || !target.closest(".cm-search")) return;
    e.preventDefault();
    e.stopPropagation();
    stepSearchMatch(e.key === "ArrowUp");
  },
  true
);

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
    if (!url) return;
    // 文内锚点（#标题）：按 GitHub slug 匹配标题并滚动（目录跳转）
    if (url.startsWith("#")) {
      const line = matchHeadingLine(url.slice(1), collectOutline());
      if (line != null) scrollToLine(line);
      return;
    }
    Bridge.notify("editor.openLink", { url });
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
