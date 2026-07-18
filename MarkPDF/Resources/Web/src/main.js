// MarkPDF Markdown 编辑器内核入口（FR-2.1 / FR-2.2 / FR-2.7）
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, placeholder } from "@codemirror/view";
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
Bridge.onMessage("editor.scrollToLine", (p) => {
  const line = Math.max(1, Math.min(p.line ?? 1, view.state.doc.lines));
  const pos = view.state.doc.line(line).from;
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: "start" }),
  });
  view.focus();
});

Bridge.notify("editor.ready", { version: "0.1.0" });

// 调试句柄：供 native 探针/浏览器控制台诊断坐标映射（不影响功能）
window.__cmView = view;
