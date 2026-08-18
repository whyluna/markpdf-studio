// MarkPDF Markdown 编辑器内核入口（FR-2.1 / FR-2.2 / FR-2.7）
import { EditorState, Compartment, StateField, Transaction } from "@codemirror/state";
import { t as uiText } from "./strings.js";
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
  // 注释不用斜体：CJK 无真斜体字形，伪斜体变形观感差（GitHub 渲染同样不斜体）
  { tag: t.comment, color: "var(--tok-c)" },
  { tag: [t.function(t.variableName), t.propertyName, t.typeName], color: "var(--tok-f)" },
  { tag: [t.number, t.atom, t.bool], color: "var(--tok-n)" },
  { tag: t.variableName, color: "var(--tok-v)" },
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
// 扩容语言（P1-1，全部 legacy-modes，零新依赖；与 wysiwyg.js FENCE_LANGS 保持同步）
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { r } from "@codemirror/legacy-modes/mode/r";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { nginx } from "@codemirror/legacy-modes/mode/nginx";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { http } from "@codemirror/legacy-modes/mode/http";
import { groovy } from "@codemirror/legacy-modes/mode/groovy";
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { erlang } from "@codemirror/legacy-modes/mode/erlang";
import { elm } from "@codemirror/legacy-modes/mode/elm";
import { julia } from "@codemirror/legacy-modes/mode/julia";
import { octave } from "@codemirror/legacy-modes/mode/octave";
import { fortran } from "@codemirror/legacy-modes/mode/fortran";
import { pascal } from "@codemirror/legacy-modes/mode/pascal";
import { verilog } from "@codemirror/legacy-modes/mode/verilog";
import { vhdl } from "@codemirror/legacy-modes/mode/vhdl";
import { tcl } from "@codemirror/legacy-modes/mode/tcl";
import { vb } from "@codemirror/legacy-modes/mode/vb";
import { protobuf } from "@codemirror/legacy-modes/mode/protobuf";
import { sass } from "@codemirror/legacy-modes/mode/sass";
import { stylus } from "@codemirror/legacy-modes/mode/stylus";
import { coffeeScript } from "@codemirror/legacy-modes/mode/coffeescript";
import { crystal } from "@codemirror/legacy-modes/mode/crystal";
import { d } from "@codemirror/legacy-modes/mode/d";
import { xml } from "@codemirror/legacy-modes/mode/xml";

// 代码块语法高亮语言白名单（控制内核体积；legacy StreamLanguage 需显式包裹 LanguageSupport）
const legacy = (mode) => new LanguageSupport(StreamLanguage.define(mode));
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
  // P1-1 扩容（legacy-modes，名称/别名与常见 fence 写法对齐）
  LanguageDescription.of({ name: "dockerfile", alias: ["docker"], support: legacy(dockerFile) }),
  LanguageDescription.of({ name: "ruby", alias: ["rb"], support: legacy(ruby) }),
  LanguageDescription.of({ name: "perl", support: legacy(perl) }),
  LanguageDescription.of({ name: "lua", support: legacy(lua) }),
  LanguageDescription.of({ name: "r", support: legacy(r) }),
  LanguageDescription.of({ name: "powershell", alias: ["ps1"], support: legacy(powerShell) }),
  LanguageDescription.of({ name: "toml", support: legacy(toml) }),
  LanguageDescription.of({ name: "ini", alias: ["properties", "conf"], support: legacy(properties) }),
  LanguageDescription.of({ name: "nginx", support: legacy(nginx) }),
  LanguageDescription.of({ name: "diff", alias: ["patch"], support: legacy(diff) }),
  LanguageDescription.of({ name: "http", support: legacy(http) }),
  LanguageDescription.of({ name: "groovy", support: legacy(groovy) }),
  LanguageDescription.of({ name: "clojure", alias: ["clj"], support: legacy(clojure) }),
  LanguageDescription.of({ name: "haskell", alias: ["hs"], support: legacy(haskell) }),
  LanguageDescription.of({ name: "erlang", support: legacy(erlang) }),
  LanguageDescription.of({ name: "elm", support: legacy(elm) }),
  LanguageDescription.of({ name: "julia", support: legacy(julia) }),
  LanguageDescription.of({ name: "octave", alias: ["matlab"], support: legacy(octave) }),
  LanguageDescription.of({ name: "fortran", support: legacy(fortran) }),
  LanguageDescription.of({ name: "pascal", alias: ["delphi"], support: legacy(pascal) }),
  LanguageDescription.of({ name: "verilog", support: legacy(verilog) }),
  LanguageDescription.of({ name: "vhdl", support: legacy(vhdl) }),
  LanguageDescription.of({ name: "tcl", support: legacy(tcl) }),
  LanguageDescription.of({ name: "vb", alias: ["vbscript"], support: legacy(vb) }),
  LanguageDescription.of({ name: "protobuf", alias: ["proto"], support: legacy(protobuf) }),
  LanguageDescription.of({ name: "sass", alias: ["scss"], support: legacy(sass) }),
  LanguageDescription.of({ name: "stylus", support: legacy(stylus) }),
  LanguageDescription.of({ name: "coffeescript", alias: ["coffee"], support: legacy(coffeeScript) }),
  LanguageDescription.of({ name: "crystal", support: legacy(crystal) }),
  LanguageDescription.of({ name: "d", alias: ["dlang"], support: legacy(d) }),
  LanguageDescription.of({ name: "xml", support: legacy(xml) }),
];
import { wysiwyg } from "./wysiwyg.js";
import * as Bridge from "./bridge.js";
import { docContext } from "./doccontext.js";
import { buildExport } from "./exporthtml.js";
import { matchHeadingLine } from "./extended.js";

// <html lang> 跟随内核语言：index.html 静态硬编码 zh-CN，此处按 ?lang= 纠正；
// 取值口径与 strings.js currentLang() 一致（currentLang 未导出，同源复述勿漂移）
document.documentElement.lang = new URLSearchParams(location.search).get("lang") === "en" ? "en" : "zh";

// mermaid 懒加载脚本供给地址（P1-4）：App 内由 native 经 ?mmd= 传入 markpdf-file://
// 协议地址（file:// 页面动态 <script> 被拦）；浏览器调试缺省走相对路径
{
  const mmd = new URLSearchParams(location.search).get("mmd");
  if (mmd) docContext.mermaidScriptURL = mmd;
}

/* ---------- 模式（FR-2.2） ---------- */

const modeConf = new Compartment();

// 撤销历史放 Compartment：切换文档时整体重置——单 WebView 换档架构下，
// 跨文档 ⌘Z 会把上一文件的内容写进当前文件/清空文件（恶性数据丢失）
const historyConf = new Compartment();

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

// 文本级选区高亮：mark 装饰只包裹实际文字（CM6 drawSelection 对整行选区会画满行宽色块，
// 无内建「贴合文字」选项；mark 跨行时按行截断、只覆盖文字，选区即所见即所得）
const selTextField = StateField.define({
  create(state) {
    return selTextDecos(state);
  },
  update(_deco, tr) {
    return tr.selection || tr.docChanged ? selTextDecos(tr.state) : _deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

function selTextDecos(state) {
  const marks = [];
  for (const r of state.selection.ranges) {
    if (!r.empty) marks.push(Decoration.mark({ class: "cm-sel-text" }).range(r.from, r.to));
  }
  return Decoration.set(marks, true);
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
  // drawSelection 的整行选区色块关闭——改用 selTextField 的文本级高亮。
  // 必须覆盖 CM 内建聚焦态全路径规则（5 类选择器 .cm-focused > .cm-scroller > .cm-selectionLayer …），
  // 否则焦点态被 #d7d4f0 色块打败，与文本级高亮叠出双层（实测注入 CSS 确认）
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    backgroundColor: "transparent",
  },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": {
    backgroundColor: "transparent",
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
    // 初始为空（防 setContent 握手丢失时误显示内容）；浏览器调试自行粘贴文本
    doc: "",
    extensions: [
      historyConf.of(history()),
      // 自绘光标/选区：替代 WebKit 原生光标（原生按 line-height 1.8 的行框绘制，显得过长）
      drawSelection(),
      search({ top: true }),
      keymap.of([...searchKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
      ...baseExtensions(),
      placeholder(uiText("placeholder")),
      modeConf.of(modeExtension("wysiwyg")),
      // 打字机/专注模式（FR-2.10）：默认关，经 editor.setTypewriter/setFocusMode 重配置
      typewriterConf.of([]),
      focusConf.of([]),
      selTextField,
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
    notifyTimer = null;
    Bridge.notify("editor.contentChanged", { text: view.state.doc.toString() });
    Bridge.notify("editor.outline", { items: collectOutline() });
  }, 300);
}

// 页面隐藏/卸载前立即发出挂起的内容变更：防抖 300ms 窗口内的尾巴不丢（FR-2.7）。
// 切标签/关标签时 SwiftUI 直接销毁 webView，等不到防抖触发
function flushPendingNotify() {
  if (notifyTimer == null) return;
  clearTimeout(notifyTimer);
  notifyTimer = null;
  Bridge.notify("editor.contentChanged", { text: view.state.doc.toString() });
  Bridge.notify("editor.outline", { items: collectOutline() });
}
window.addEventListener("pagehide", flushPendingNotify);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushPendingNotify();
});

/* ---------- 光标行上报（防抖 150ms，FR-1.6 编辑位置记忆 + 大纲当前节跟随） ----------
   曾为落盘记忆设 500ms，大纲跟随上线后体感延迟明显；落盘侧自有防抖，缩短无负担 */

const cursorTimerDelay = 150;
let cursorTimer = null;
function scheduleCursorNotify() {
  clearTimeout(cursorTimer);
  cursorTimer = setTimeout(() => {
    const line = view.state.doc.lineAt(view.state.selection.main.head).number;
    Bridge.notify("editor.cursor", { line });
  }, cursorTimerDelay);
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
      let text = line.text.replace(/^#{1,6}\s*/, "");
      // ATX 闭合序列不属标题文本（CommonMark：闭合 # 串前须空白）；Setext 无此规则
      if (m[1]) text = text.replace(/\s+#+\s*$/, "");
      text = text.trim();
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
  // 换档替换全文不入撤销栈，且随后清空整个历史：
  // 否则 ⌘Z 会撤销「换档」本身 → 内核回退到上一文档 → 经 contentChanged + 自动保存写坏当前文件
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: p.text ?? "" },
    annotations: Transaction.addToHistory.of(false),
  });
  view.dispatch({ effects: historyConf.reconfigure(history()) });
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

// 编辑器排版（FR-7.2）：字体/字号/行高/段距 → CSS 变量，即时生效
Bridge.onMessage("editor.setTypography", (p) => {
  const style = document.documentElement.style;
  if (typeof p.fontSize === "number") style.setProperty("--editor-font-size", `${p.fontSize}px`);
  if (typeof p.lineHeight === "number") style.setProperty("--editor-line-height", String(p.lineHeight));
  // 段距（美化第二阶段）：块间空行行高系数
  if (typeof p.paraGap === "number") style.setProperty("--editor-para-gap", String(p.paraGap));
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

// AI 助手（FR-AI.2）：取当前选区（无选区应答 text=""）
Bridge.onMessage("editor.getSelection", (_p, id) => {
  const { from, to } = view.state.selection.main;
  Bridge.respond(id, { text: view.state.sliceDoc(from, to), from, to });
});

// AI 助手（FR-AI.2）：替换选区。空选区显式拒绝（与 insertAtCursor 的
// 「空选区=光标处插入」语义区分）；正常 dispatch 入撤销栈，⌘Z 可回
Bridge.onMessage("editor.replaceSelection", (p, id) => {
  if (view.state.selection.main.empty) {
    Bridge.respond(id, { replaced: false });
    return;
  }
  view.dispatch(view.state.replaceSelection(p.text ?? ""));
  Bridge.respond(id, { replaced: true });
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
  // 非整数/NaN/Infinity 防御：doc.line 要求 1..doc.lines 的整数（doc.line(0.5) 抛 RangeError），
  // initialLine 等 native 载荷经同一入口统一收口（截尾取整后 clamp）
  const n = Number.isFinite(line) ? Math.trunc(line) : 1;
  const clamped = Math.max(1, Math.min(n, view.state.doc.lines));
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
  // SearchQuery 是规格对象，nextMatch/prevMatch 在其 create() 的 QueryType 上。
  // 越过末/首命中时回绕（nextMatch 越界返回 null 即停，与面板按钮的回绕行为对齐）
  const qt = query.create();
  const match = backward
    ? qt.prevMatch(view.state, main.from, main.from) ??
      qt.prevMatch(view.state, view.state.doc.length, view.state.doc.length)
    : qt.nextMatch(view.state, main.to, main.to) ?? qt.nextMatch(view.state, 0, 0);
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
    // 桥协议暂无错误上报通道（MessageType 无 editor.error）：3s 超时 / FileReader 失败
    // 只能留控制台诊断（WKWebView 可用 Safari Web 检查器查看），避免完全静默
    .catch((err) => console.error("[markpdf] 图片存盘失败：", err));
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

// 就绪通知：不带 version 字段——native 两侧 ready 处理器（MarkdownEditorView /
// MarkdownExportSession）均不读 payload，硬编码版本号只会与应用版本脱节
Bridge.notify("editor.ready");

// 调试句柄：供 native 探针/浏览器控制台诊断坐标映射（不影响功能）
window.__cmView = view;
