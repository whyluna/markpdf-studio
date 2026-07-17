// MarkPDF Markdown 编辑器内核入口（FR-2.1 / FR-2.2 / FR-2.7）
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, placeholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle, LanguageDescription, StreamLanguage } from "@codemirror/language";
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
  LanguageDescription.of({ name: "bash", alias: ["sh", "shell", "zsh"], support: StreamLanguage.define(shell) }),
  LanguageDescription.of({ name: "c", support: cpp() }),
  LanguageDescription.of({ name: "cpp", alias: ["c++"], support: cpp() }),
  LanguageDescription.of({ name: "java", support: java() }),
  LanguageDescription.of({ name: "rust", alias: ["rs"], support: rust() }),
  LanguageDescription.of({ name: "go", alias: ["golang"], support: StreamLanguage.define(go) }),
  LanguageDescription.of({ name: "swift", support: StreamLanguage.define(swift) }),
  LanguageDescription.of({ name: "sql", support: sql() }),
  LanguageDescription.of({ name: "html", support: html() }),
  LanguageDescription.of({ name: "css", support: css() }),
];
import { wysiwyg } from "./wysiwyg.js";
import * as Bridge from "./bridge.js";
import { DEMO_DOC } from "./demo.js";

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
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      markdown({ base: markdownLanguage, codeLanguages }),
      syntaxHighlighting(mdHighlight),
      baseTheme,
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
  }, 300);
}

/* ---------- native → web 消息注册 ---------- */

Bridge.onMessage("editor.setContent", (p) => {
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

Bridge.notify("editor.ready", { version: "0.1.0" });
