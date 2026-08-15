// 所见即所得装饰层（FR-2.1）
// 原理：解析 lezer markdown 语法树，对「光标不在场」的语法标记施加隐藏/替换装饰，
// 对块级结构施加行样式；光标进入对应行/块时撤销装饰，显露源码（Typora 式手感）。
import { EditorView, Decoration, WidgetType } from "@codemirror/view";
import { RangeSetBuilder, StateField } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import katex from "katex";
import { docContext } from "./doccontext.js";
import { t } from "./strings.js";
import { scanExtended } from "./extended.js";

/* ---------- 小部件 ---------- */

// 任务列表复选框：点击直接改写源码 [ ] ↔ [x]
class CheckboxWidget extends WidgetType {
  constructor(checked, pos) {
    super();
    this.checked = checked;
    this.pos = pos;
  }
  eq(o) {
    return o.checked === this.checked && o.pos === this.pos;
  }
  toDOM(view) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "cm-task-checkbox";
    box.checked = this.checked;
    box.addEventListener("mousedown", (e) => {
      e.preventDefault();
      view.dispatch({
        changes: { from: this.pos, to: this.pos + 3, insert: this.checked ? "[ ]" : "[x]" },
      });
    });
    return box;
  }
  ignoreEvent() {
    return false;
  }
}

// 语言选择白名单（与 main.js codeLanguages 高亮子集同步；空值 = 纯文本）
const FENCE_LANGS = [
  "", "python", "javascript", "typescript", "json", "yaml", "bash",
  "c", "cpp", "java", "rust", "go", "swift", "sql", "html", "css",
];

// 复制按钮图标（经典双矩形）与点击后的对勾反馈；用 currentColor 跟随主题色
const COPY_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8.5" rx="1.5"/><path d="M3 10.2V3.2A1.7 1.7 0 0 1 4.7 1.5H11"/></svg>';
const CHECK_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-6.5"/></svg>';

// 代码块起始 fence 行 → 语言栏：左侧语言选择（label + 隐形 select 覆盖），右侧复制按钮。
// 选择语言改写 fence 的语言标识（高亮随 CodeInfo 即时切换）；复制提取本块正文写剪贴板
class FenceBadgeWidget extends WidgetType {
  constructor(lang) {
    super();
    this.lang = lang;
  }
  eq(o) {
    return o.lang === this.lang;
  }
  toDOM(view) {
    const el = document.createElement("span");
    el.className = "cm-fence-badge";

    // 左：语言选择（label 展示 + 覆盖其上的隐形原生 select）
    const langWrap = document.createElement("span");
    langWrap.className = "cm-fence-lang-wrap";
    const label = document.createElement("span");
    label.className = "cm-fence-label";
    label.textContent = `${this.lang || "plain text"} ▾`;
    const select = document.createElement("select");
    select.className = "cm-fence-lang";
    // 文档里的非白名单语言（如 vue）也保留为可选项，避免 select 值失配
    const langs = FENCE_LANGS.includes(this.lang) ? FENCE_LANGS : [this.lang, ...FENCE_LANGS];
    for (const lang of langs) {
      const option = document.createElement("option");
      option.value = lang;
      option.textContent = lang || "plain text";
      select.append(option);
    }
    select.value = this.lang;
    select.addEventListener("change", () => {
      // 位置动态解析（文档可能已变，不能用构造时的偏移）
      const pos = view.posAtDOM(el);
      const line = view.state.doc.lineAt(pos);
      const m = /^(\s*(?:`{3,}|~{3,})\s*)/.exec(line.text);
      if (!m) return;
      view.dispatch({
        changes: { from: line.from + m[1].length, to: line.to, insert: select.value },
      });
    });
    langWrap.append(label, select);

    // 右：复制按钮（图标；提取本 fence 块正文）
    const copy = document.createElement("button");
    copy.className = "cm-fence-copy";
    copy.title = t("copyCode");
    copy.innerHTML = COPY_ICON;
    copy.addEventListener("click", (e) => {
      e.preventDefault();
      const code = fenceCodeText(view, el);
      if (code == null) return;
      copyToClipboard(code);
      copy.innerHTML = CHECK_ICON;
      copy.classList.add("copied");
      setTimeout(() => {
        copy.innerHTML = COPY_ICON;
        copy.classList.remove("copied");
      }, 1200);
    });

    el.append(langWrap, copy);
    return el;
  }
}

// 从 badge 所在 fence 首行定位整个代码块，返回正文（不含首尾 fence 行）
function fenceCodeText(view, badgeEl) {
  const doc = view.state.doc;
  const firstLine = doc.lineAt(view.posAtDOM(badgeEl));
  const fenceRe = /^(\s*)(`{3,}|~{3,})/;
  const open = fenceRe.exec(firstLine.text);
  if (!open) return null;
  // 关闭 fence 后只允许空白（CommonMark）：代码块内的 ``` 注释行不得提前截断
  const closeRe = /^\s*(`{3,}|~{3,})\s*$/;
  const lines = [];
  for (let n = firstLine.number + 1; n <= doc.lines; n++) {
    const ln = doc.line(n);
    const close = closeRe.exec(ln.text);
    // 结束 fence：同种围栏字符且长度不短于起始
    if (close && close[1][0] === open[2][0] && close[1].length >= open[2].length) break;
    lines.push(ln.text);
  }
  return lines.join("\n");
}

// 写剪贴板：优先 Clipboard API（WKWebView file:// 为安全上下文），失败降级 execCommand
function copyToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => execCommandCopy(text));
  } else {
    execCommandCopy(text);
  }
}
function execCommandCopy(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
  document.body.append(ta);
  ta.select();
  try {
    document.execCommand("copy");
  } catch {
    /* 剪贴板不可用时静默 */
  }
  ta.remove();
}

// 代码块结束 fence 行 → 收起为细线
class FenceEndWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-fence-end";
    return el;
  }
}

// 水平线
class HRWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-hr";
    return el;
  }
}

// KaTeX 公式（FR-2.4）：displayMode 为块级（div 独占成行），否则行内（span）
//
// 大尺寸 widget 高度估计与缓存（滚动抖动修复）：CM6 视口虚拟化对未测量的
// block widget 一律按单行高估计，滚入视口测出真实高度后文档总高阶梯式突增
//（滚动条 thumb 漂移、内容跳变）。对策：①按内容给 estimatedHeight；
// ②测量高度按内容 key 缓存（widget 随视口回收/重建后估计仍准确——
// 滚动来回经过同一公式不再「单行→真实」反复跳）；
// ③KaTeX 渲染结果缓存（重建帧不再成串同步 renderToString 掉帧）
const widgetHeightCache = new Map(); // 内容 key → px（FIFO 上限 300）
const katexHtmlCache = new Map(); // displayMode+latex → HTML（FIFO 上限 500）

function cachePut(map, key, value, cap) {
  if (map.has(key)) map.delete(key);
  map.set(key, value);
  if (map.size > cap) map.delete(map.keys().next().value);
}

// toDOM 后下一帧记录真实高度（jsdom 等无布局环境 offsetHeight=0，自然跳过）
function rememberHeight(key, el) {
  requestAnimationFrame(() => {
    if (el.isConnected && el.offsetHeight > 0) {
      cachePut(widgetHeightCache, key, el.offsetHeight, 300);
    }
  });
}

class MathWidget extends WidgetType {
  constructor(latex, displayMode, source) {
    super();
    this.latex = latex;
    this.displayMode = displayMode;
    this.source = source; // 原始源码，用于 eq 去重与异常降级
  }
  eq(o) {
    return o.source === this.source && o.displayMode === this.displayMode;
  }
  // CM6 高度图的唯一估计入口（block widget；行内返回 -1 随文本行高）
  get estimatedHeight() {
    if (!this.displayMode) return -1;
    const cached = widgetHeightCache.get("m:" + this.source);
    if (cached) return cached;
    // KaTeX display 单行约 44px 含上下 padding 16；多行环境（\\ 换行）按行累加
    const rows = (this.latex.match(/\\\\/g) || []).length + 1;
    return rows * 44 + 16;
  }
  toDOM(view) {
    const el = document.createElement(this.displayMode ? "div" : "span");
    el.className = this.displayMode ? "cm-math-display" : "cm-math-inline";
    const cacheKey = (this.displayMode ? "D:" : "I:") + this.latex;
    let html = katexHtmlCache.get(cacheKey);
    if (html === undefined) {
      try {
        html = katex.renderToString(this.latex, {
          displayMode: this.displayMode,
          throwOnError: false, // 语法错误时输出错误样式，不炸编辑器
          output: "html",
        });
      } catch {
        html = null; // 极端异常降级为源码文本
      }
      cachePut(katexHtmlCache, cacheKey, html, 500);
    }
    if (html != null) {
      el.innerHTML = html;
    } else {
      el.textContent = this.source;
    }
    if (this.displayMode) rememberHeight("m:" + this.source, el);
    // 块级单击、行内双击 → 光标落回公式源码处，显露源码进入编辑
    // （位置由 posAtDOM 实时解析，不怕上文编辑偏移；阅读模式 alwaysRender 下重渲染后仍是渲染态）
    el.addEventListener(this.displayMode ? "mousedown" : "dblclick", (e) => {
      e.preventDefault();
      const pos = view.posAtDOM(el);
      view.dispatch({ selection: { anchor: pos } });
      view.focus();
    });
    return el;
  }
  ignoreEvent() {
    return false;
  }
}

// 跳转到指定行并居中滚动（脚注引用/回跳共用）。
// 只滚动、不动光标：光标落进定义行会使该行变「活跃」显露源码、↩ 回跳标记被隐藏（回跳失灵的根因）
function jumpToLine(view, line) {
  if (line == null || line < 1 || line > view.state.doc.lines) return;
  const pos = view.state.doc.line(line).from;
  view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: "center" }) });
}

// 脚注引用上标（FR-2.4）：[^label] → [n]（编号按首次引用顺序）。
// 单击跳到定义行；双击（mousedown detail≥2）落光标显露源码。
// 跳转必须挂 mousedown + preventDefault（CheckboxWidget 同款成熟模式）：click 时机太晚——
// WebKit 在 mousedown 默认行为里把光标放到 widget 旁的可编辑位置，行变活跃、widget 被
// 装饰重建销毁，click 到不了（真机点击无反应的根因；合成 click 不走原生落标路径测不出）
class FootnoteRefWidget extends WidgetType {
  constructor(n, label, defLine) {
    super();
    this.n = n;
    this.label = label;
    this.defLine = defLine;
  }
  eq(o) {
    return o.n === this.n && o.label === this.label && o.defLine === this.defLine;
  }
  toDOM(view) {
    const el = document.createElement("sup");
    el.className = "cm-footnote-ref";
    el.textContent = `[${this.n}]`;
    el.addEventListener("mousedown", (e) => {
      e.preventDefault();
      if (e.detail >= 2) {
        const pos = view.posAtDOM(el);
        view.dispatch({ selection: { anchor: pos } });
        view.focus();
      } else {
        jumpToLine(view, this.defLine);
      }
    });
    return el;
  }
}

// 脚注定义行回跳标记（GitHub ↩ 惯例）：定义↔引用按 label 唯一对应，
// 同一 label 可被多处引用，回跳到第一处引用。mousedown + preventDefault 同上
class FootnoteBackRefWidget extends WidgetType {
  constructor(refLine) {
    super();
    this.refLine = refLine;
  }
  eq(o) {
    return o.refLine === this.refLine;
  }
  toDOM(view) {
    const el = document.createElement("span");
    el.className = "cm-footnote-backref";
    el.textContent = "↩";
    el.addEventListener("mousedown", (e) => {
      e.preventDefault();
      jumpToLine(view, this.refLine);
    });
    return el;
  }
}

// 渲染态图片（FR-2.3）：光标不在行内时把 ![alt](src) 替换为真实图片；双击进入源码编辑
class ImageWidget extends WidgetType {
  constructor(src, alt) {
    super();
    this.src = src; // 已解析为 markpdf-file:// 绝对地址
    this.alt = alt;
  }
  eq(o) {
    return o.src === this.src && o.alt === this.alt;
  }
  toDOM(view) {
    let el;
    if (!this.src) {
      el = document.createElement("span");
      el.className = "cm-image-broken";
      el.textContent = `🖼 ${this.alt || t("imageFallbackAlt")}${t("imageDraftUnsupported")}`;
    } else {
      el = document.createElement("img");
      el.className = "cm-rendered-image";
      el.src = this.src;
      el.alt = this.alt;
      // 加载完成后让 CM 重测行高：异步加载前按单行估计、加载后图片撑高行，
      // CM 的 ResizeObserver 不感知内容高度变化，不主动重测会留下高度差（滚动跳变）
      el.onload = () => view.requestMeasure();
      el.onerror = () => {
        const span = document.createElement("span");
        span.className = "cm-image-broken";
        span.textContent = `🖼 ${t("imageLoadFailed")}${this.alt || this.src}`;
        el.replaceWith(span);
      };
    }
    // 双击 → 光标落到图片语法处，显露源码进入编辑（位置由 posAtDOM 实时解析，不怕上文编辑偏移）
    el.addEventListener("dblclick", (e) => {
      e.preventDefault();
      const pos = view.posAtDOM(el);
      view.dispatch({ selection: { anchor: pos } });
      view.focus();
    });
    return el;
  }
  ignoreEvent() {
    return false;
  }
}

// 渲染态表格（FR-2.3）：光标在表格外时整体替换为 HTML 表格；点击进入源码编辑
class TableWidget extends WidgetType {
  constructor(model, source) {
    super();
    this.model = model; // { header: [segs], rows: [[segs]], rowOffsets: [int] }
    this.source = source; // 表格源码文本，用于 eq 去重
  }
  eq(o) {
    return o.source === this.source;
  }
  get estimatedHeight() {
    const cached = widgetHeightCache.get("t:" + this.source);
    if (cached) return cached;
    // 行高 = 单元格 padding 16 + 文本行 ~22；表头也算一行；上下 padding 16
    return (this.model.rows.length + 1) * 38 + 16;
  }
  toDOM(view) {
    const wrap = document.createElement("div");
    wrap.className = "cm-table-widget";
    rememberHeight("t:" + this.source, wrap);
    const table = document.createElement("table");

    const appendSegs = (cellEl, segs) => {
      for (const seg of segs) {
        const el = document.createElement("span");
        el.textContent = seg.text;
        if (seg.marks.includes("b")) el.style.fontWeight = "650";
        if (seg.marks.includes("i")) el.style.fontStyle = "italic";
        if (seg.marks.includes("s")) el.style.textDecoration = "line-through";
        if (seg.marks.includes("c")) el.classList.add("cm-inline-code");
        // classList.add 累加：单元格同时是 code+link 时两类都要保留（className 二次赋值会覆盖）
        if (seg.marks.includes("a")) el.classList.add("cm-link");
        cellEl.appendChild(el);
      }
    };

    const thead = document.createElement("thead");
    const htr = document.createElement("tr");
    htr.dataset.row = 0;
    for (const segs of this.model.header) {
      const th = document.createElement("th");
      appendSegs(th, segs);
      htr.appendChild(th);
    }
    thead.appendChild(htr);
    table.appendChild(thead);

    const tbody = document.createElement("tbody");
    this.model.rows.forEach((row, i) => {
      const tr = document.createElement("tr");
      tr.dataset.row = i + 1;
      for (const segs of row) {
        const td = document.createElement("td");
        appendSegs(td, segs);
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    wrap.appendChild(table);

    // 点击某行 → 光标落入对应源码行，表格显露源码进入编辑
    // （行偏移 + posAtDOM 实时解析表格起点，上文编辑导致的位置偏移不会造成跳错行）
    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const tr = e.target.closest("tr");
      // 点在表格 padding 等非行区域（无 tr）：落首行（表头），而非回退最后一行——
      // 从上方点击表格时光标跳表尾违和，表头是更自然的入口
      const idx = tr ? Number(tr.dataset.row) : 0;
      const base = view.posAtDOM(wrap);
      const pos = base + this.model.rowOffsets[Math.min(idx, this.model.rowOffsets.length - 1)];
      view.dispatch({ selection: { anchor: pos } });
      view.focus();
    });
    return wrap;
  }
  ignoreEvent() {
    return false;
  }
}

/* ---------- 工具 ---------- */

// 选区是否触及 [from, to]
function rangeActive(state, from, to) {
  for (const r of state.selection.ranges) {
    if (r.from <= to && r.to >= from) return true;
  }
  return false;
}

// 选区是否触及 pos 所在的整行
function lineActive(state, pos) {
  const line = state.doc.lineAt(pos);
  return rangeActive(state, line.from, line.to);
}

const headingClass = {
  ATXHeading1: "cm-h1",
  ATXHeading2: "cm-h2",
  ATXHeading3: "cm-h3",
  ATXHeading4: "cm-h4",
  ATXHeading5: "cm-h5",
  ATXHeading6: "cm-h6",
  SetextHeading1: "cm-h1",
  SetextHeading2: "cm-h2",
};

/* ---------- 表格模型解析 ---------- */

// 单元格内联内容 → 带样式片段（marks: b=粗 i=斜 s=删 c=行内代码 a=链接）
function cellSegments(state, cell) {
  const segs = [];
  const emit = (f, t, marks) => {
    if (f < t) segs.push({ text: state.doc.sliceString(f, t), marks });
  };
  const SKIP = new Set(["EmphasisMark", "CodeMark", "StrikethroughMark", "LinkMark", "URL"]);
  const walk = (node, marks) => {
    if (SKIP.has(node.name)) return;
    let m = marks;
    if (node.name === "StrongEmphasis") m += "b";
    else if (node.name === "Emphasis") m += "i";
    else if (node.name === "Strikethrough") m += "s";
    else if (node.name === "InlineCode") m += "c";
    else if (node.name === "Link") m += "a";
    let pos = node.from;
    for (let c = node.firstChild; c; c = c.nextSibling) {
      emit(pos, c.from, m); // 命名节点之间的间隙是纯文本
      walk(c, m);
      pos = c.to;
    }
    emit(pos, node.to, m);
  };
  let pos = cell.from;
  for (let c = cell.firstChild; c; c = c.nextSibling) {
    emit(pos, c.from, "");
    walk(c, "");
    pos = c.to;
  }
  emit(pos, cell.to, "");
  return segs;
}

// 图片 src 解析（FR-2.3）：相对路径按文档目录解析为 markpdf-file:// 绝对地址
// （WKWebView 沙盒无法直接读工作区文件，走自定义协议由 native 供给）；
// http(s)/data:/blob: 原样返回；无基准目录（草稿）返回 null 触发降级提示
function resolveImageURL(src) {
  if (/^(https?:|data:|blob:)/i.test(src)) return src;
  if (!docContext.baseURL) return null;
  try {
    const abs = new URL(src, docContext.baseURL);
    return "markpdf-file://" + abs.host + abs.pathname;
  } catch {
    return null;
  }
}

// 遍历 Table 节点，提取表头/数据行单元格与各行相对表格起点的偏移；解析失败返回 null（降级源码样式）
function buildTableModel(state, tableNode) {
  const header = [];
  const rows = [];
  const rowOffsets = [];
  let widgetFrom = -1;
  for (let child = tableNode.firstChild; child; child = child.nextSibling) {
    if (child.name !== "TableHeader" && child.name !== "TableRow") continue;
    const lineFrom = state.doc.lineAt(child.from).from;
    if (widgetFrom < 0) widgetFrom = lineFrom;
    const cells = [];
    for (let cell = child.firstChild; cell; cell = cell.nextSibling) {
      if (cell.name === "TableCell") cells.push(cellSegments(state, cell));
    }
    rowOffsets.push(lineFrom - widgetFrom);
    if (child.name === "TableHeader") header.push(...cells);
    else rows.push(cells);
  }
  if (header.length === 0) return null;
  return { header, rows, rowOffsets };
}

/* ---------- 装饰构建 ---------- */

// (doc, 语法树) 级重活：排除范围收集（全树遍历）+ scanExtended（全文字符串化 + 三轮正则扫描）。
// 结果只依赖 (state.doc, syntaxTree)、与选区无关，故可按引用记忆化（见 wysiwyg() 内 scanOf）：
// 纯选区交易（方向键/点击）复用缓存，文档变化（doc 引用必变）或后台解析推进（tree 引用变化）时失效重建
function computeScan(state) {
  // 收集排除范围。代码区内三种语法不生效；
  // 图片/表格会被整体 replace，其内部再叠加 replace 会互相重叠，一并排除
  const excludeRanges = [];
  // 带 URL 子节点的 Link（如 `[^a](x)`：lezer 整体解析为 Link）：仅脚注扫描排除——
  // 该写法按链接渲染，前缀 `[^a]` 不得再生成脚注 widget（与 Link 隐藏装饰 replace 相交，
  // CM 明令禁止、行为未定义）；纯脚注引用 `[^a]`（无 URL 子节点）不在此列，照常渲染上标
  const footnoteExcludes = [];
  syntaxTree(state).iterate({
    enter(node) {
      if (
        node.name === "InlineCode" ||
        node.name === "FencedCode" ||
        node.name === "IndentedCode" ||
        node.name === "Image" ||
        node.name === "Table"
      ) {
        excludeRanges.push({ from: node.from, to: node.to });
        return;
      }
      if (node.name === "Link") {
        for (let c = node.node.firstChild; c; c = c.nextSibling) {
          if (c.name === "URL") {
            footnoteExcludes.push({ from: node.from, to: node.to });
            break;
          }
        }
      }
    },
  });
  const ext = scanExtended(state.doc.toString(), excludeRanges, footnoteExcludes);
  return { doc: state.doc, tree: syntaxTree(state), ext };
}

function buildDecorations(state, alwaysRender, ext) {
  const decos = [];
  const addMark = (from, to, cls) => {
    if (from < to) decos.push({ from, to, deco: Decoration.mark({ class: cls }) });
  };
  const addHide = (from, to) => {
    if (from <= to) decos.push({ from, to, deco: Decoration.replace({}) });
  };
  const addLine = (from, cls) => {
    decos.push({ from, to: from, deco: Decoration.line({ class: cls }) });
  };
  const addWidgetReplace = (from, to, widget) => {
    decos.push({ from, to, deco: Decoration.replace({ widget }) });
  };
  const addWidget = (from, widget) => {
    decos.push({ from, to: from, deco: Decoration.widget({ widget, side: 1 }) });
  };

  // active 判定：阅读模式（alwaysRender）下永不显露源码
  const isLineActive = (pos) => !alwaysRender && lineActive(state, pos);
  const isRangeActive = (from, to) => !alwaysRender && rangeActive(state, from, to);

  /* ---- 扩展语法（FR-2.4）：数学公式 / 高亮 / 脚注（扫描结果由调用方按 (doc, 语法树) 记忆化供给） ---- */

  // 扩展语法当前生效的 replace 范围：树装饰落在其中必须抑制（避免 replace 重叠，
  // 如公式块内的强调标记、被识别为 Link 的脚注引用 [^a]）
  const extReplaces = [];

  for (const m of ext.maths) {
    if (isRangeActive(m.from, m.to)) continue; // 光标在场 → 显露源码
    const source = state.doc.sliceString(m.from, m.to);
    const widget = new MathWidget(m.latex, m.displayMode, source);
    if (m.displayMode) {
      // 块级公式：所在行首尾仅剩空白时按行边界整块替换；嵌在行内则退为行内 widget
      const startLine = state.doc.lineAt(m.from);
      const endLine = state.doc.lineAt(m.to);
      const alone =
        /^\s*$/.test(startLine.text.slice(0, m.from - startLine.from)) &&
        /^\s*$/.test(endLine.text.slice(m.to - endLine.from));
      if (alone) {
        decos.push({
          from: startLine.from,
          to: endLine.to,
          deco: Decoration.replace({ widget, block: true }),
        });
        extReplaces.push({ from: startLine.from, to: endLine.to });
        continue;
      }
    }
    addWidgetReplace(m.from, m.to, widget);
    extReplaces.push({ from: m.from, to: m.to });
  }

  for (const h of ext.highlights) {
    // 高亮内容始终带底色（对齐 Emphasis 的显隐策略），光标不在场时隐藏两侧 ==
    addMark(h.contentFrom, h.contentTo, "cm-highlight");
    if (!isRangeActive(h.from, h.to)) {
      addHide(h.openFrom, h.openTo);
      addHide(h.closeFrom, h.closeTo);
    }
  }

  for (const r of ext.footnoteRefs) {
    if (isRangeActive(r.from, r.to)) continue;
    // 定义行号（可能缺失——悬空引用不跳转）
    const def = ext.footnoteDefs.find((d) => d.label === r.label);
    const defLine = def ? state.doc.lineAt(def.markerFrom).number : null;
    addWidgetReplace(r.from, r.to, new FootnoteRefWidget(r.n, r.label, defLine));
    extReplaces.push({ from: r.from, to: r.to });
  }

  for (const d of ext.footnoteDefs) {
    addLine(state.doc.lineAt(d.markerFrom).from, "cm-footnote-def");
    if (!isLineActive(d.markerFrom)) {
      addHide(d.markerFrom, d.markerTo);
      // 定义行可能被语法树解析为 Paragraph+Link（前缀 [^label] 的 [ ] 会被 Link 分支隐藏），
      // 标记隐藏范围同样需抑制树装饰
      extReplaces.push({ from: d.markerFrom, to: d.markerTo });
      // 行尾回跳标记 ↩：跳回第一处引用（多对一取首个）
      const firstRef = ext.footnoteRefs.find((r) => r.label === d.label);
      if (firstRef) {
        addWidget(state.doc.lineAt(d.markerFrom).to, new FootnoteBackRefWidget(state.doc.lineAt(firstRef.from).number));
      }
    }
  }

  syntaxTree(state).iterate({
    enter(node) {
      const { name, from, to } = node;

      // 落在扩展语法 replace 范围内的节点不再装饰（避免 replace 重叠）
      for (const r of extReplaces) {
        if (from >= r.from && to <= r.to) return false;
      }

      // 标题行样式
      if (headingClass[name]) {
        addLine(state.doc.lineAt(from).from, headingClass[name]);
        return;
      }

      switch (name) {
        case "HeaderMark": {
          // ATX 的 # 序列：光标不在本行时连同尾随空格一起隐藏
          if (!isLineActive(from)) {
            const end = state.doc.sliceString(to, to + 1) === " " ? to + 1 : to;
            addHide(from, end);
          }
          return false;
        }

        case "EmphasisMark":
        case "CodeMark":
        case "StrikethroughMark": {
          if (!isLineActive(from)) addHide(from, to);
          return false;
        }

        case "Emphasis":
          addMark(from, to, "cm-em");
          return;
        case "StrongEmphasis":
          addMark(from, to, "cm-strong");
          return;
        case "Strikethrough":
          addMark(from, to, "cm-strike");
          return;
        case "InlineCode":
          addMark(from, to, "cm-inline-code");
          return;

        case "Link": {
          // 隐藏 [ ] ( ) 与 URL，仅保留带样式的链接文字
          addMark(from, to, "cm-link");
          for (let c = node.node.firstChild; c; c = c.nextSibling) {
            if ((c.name === "LinkMark" || c.name === "URL") && !isLineActive(c.from)) {
              addHide(c.from, c.to);
            }
          }
          return false;
        }

        case "Image": {
          // 光标不在行内 → 替换为真实图片（FR-2.3）；在场或无 src → 退化隐藏标记
          if (!isLineActive(from)) {
            let src = "";
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.name === "URL") src = state.doc.sliceString(c.from, c.to);
            }
            if (src) {
              const raw = state.doc.sliceString(from, to);
              const alt = (/^!\[([^\]]*)\]/.exec(raw) || [])[1] ?? "";
              addWidgetReplace(from, to, new ImageWidget(resolveImageURL(src), alt));
              return false;
            }
          }
          addMark(from, to, "cm-image");
          for (let c = node.node.firstChild; c; c = c.nextSibling) {
            if ((c.name === "LinkMark" || c.name === "URL") && !isLineActive(c.from)) {
              addHide(c.from, c.to);
            }
          }
          return false;
        }

        case "BlockQuote": {
          const first = state.doc.lineAt(from).number;
          const last = state.doc.lineAt(to).number;
          for (let n = first; n <= last; n++) addLine(state.doc.line(n).from, "cm-quote-line");
          return;
        }

        case "QuoteMark": {
          if (!isLineActive(from)) {
            const end = state.doc.sliceString(to, to + 1) === " " ? to + 1 : to;
            addHide(from, end);
          }
          return false;
        }

        case "FencedCode": {
          const firstLine = state.doc.lineAt(from);
          const lastLine = state.doc.lineAt(Math.max(from, to - 1));
          for (let n = firstLine.number; n <= lastLine.number; n++) {
            // 首/末行附加类：盒子圆角与上下内边距（编辑态 fence 行可见时也是完整盒子）
            let cls = "cm-codeblock-line";
            if (n === firstLine.number) cls += " cm-codeblock-first";
            if (n === lastLine.number) cls += " cm-codeblock-last";
            addLine(state.doc.line(n).from, cls);
          }
          if (!isRangeActive(from, to) && lastLine.number > firstLine.number) {
            // 取语言标识
            let lang = "";
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.name === "CodeInfo") lang = state.doc.sliceString(c.from, c.to).trim();
            }
            addWidgetReplace(firstLine.from, firstLine.to, new FenceBadgeWidget(lang));
            addWidgetReplace(lastLine.from, lastLine.to, new FenceEndWidget());
          }
          return false;
        }

        case "Table": {
          const first = state.doc.lineAt(from).number;
          const last = state.doc.lineAt(to).number;
          // 光标在表格内，或嵌套于引用/列表等块内 → 等宽源码（编辑态/降级）
          const nested = !!node.node.parent && node.node.parent.name !== "Document";
          const model = !isRangeActive(from, to) && !nested ? buildTableModel(state, node.node) : null;
          if (model) {
            // 离块即渲染：整体替换为 HTML 表格（块级 Widget，范围按行边界对齐）
            const source = state.doc.sliceString(from, to);
            decos.push({
              from: state.doc.line(first).from,
              to: state.doc.line(last).to,
              deco: Decoration.replace({ widget: new TableWidget(model, source), block: true }),
            });
          } else {
            for (let n = first; n <= last; n++) addLine(state.doc.line(n).from, "cm-table-line");
          }
          return false;
        }

        case "TaskMarker": {
          // "[ ]" / "[x]" → 复选框（光标在场也保持渲染，对齐 Typora）
          const checked = state.doc.sliceString(from, to).toLowerCase().includes("x");
          addWidgetReplace(from, to, new CheckboxWidget(checked, from));
          return false;
        }

        case "HorizontalRule": {
          if (!isLineActive(from)) {
            const line = state.doc.lineAt(from);
            addWidgetReplace(line.from, line.to, new HRWidget());
          }
          return false;
        }

        default:
          return;
      }
    },
  });

  decos.sort((a, b) => a.from - b.from || a.deco.startSide - b.deco.startSide);
  const builder = new RangeSetBuilder();
  for (const d of decos) builder.add(d.from, d.to, d.deco);
  return builder.finish();
}

/**
 * 所见即所得装饰
 * @param {boolean} alwaysRender true=阅读模式：全部渲染、永不显露源码
 *
 * 注意：块级装饰（表格 Widget 的 block replace）不允许经由 ViewPlugin 提供
 * （CM6 抛 "Block decorations may not be specified via plugins"），
 * 必须通过 StateField + EditorView.decorations.from 走状态侧通道。
 */
export function wysiwyg(alwaysRender) {
  // (doc, tree) 引用级重活缓存：纯选区交易复用（doc/tree 引用均未变），
  // 文档变化或语法树推进时引用必变 → 自动失效重建（与下方 update 重建条件同口径）
  let scan = null;
  const scanOf = (state) => {
    const tree = syntaxTree(state);
    if (!scan || scan.doc !== state.doc || scan.tree !== tree) scan = computeScan(state);
    return scan.ext;
  };
  return StateField.define({
    create(state) {
      return buildDecorations(state, alwaysRender, scanOf(state));
    },
    update(deco, tr) {
      if (tr.docChanged || tr.selection || syntaxTree(tr.state) !== syntaxTree(tr.startState)) {
        return buildDecorations(tr.state, alwaysRender, scanOf(tr.state));
      }
      return deco;
    },
    provide: (field) => EditorView.decorations.from(field),
  });
}

// 测试导出（estimatedHeight/高度缓存断言用；产物引用同名类，无运行时差异）
export { MathWidget, TableWidget, ImageWidget, widgetHeightCache };
