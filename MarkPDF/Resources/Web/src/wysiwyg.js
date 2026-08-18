// 所见即所得装饰层（FR-2.1）
// 原理：解析 lezer markdown 语法树，对「光标不在场」的语法标记施加隐藏/替换装饰，
// 对块级结构施加行样式；光标进入对应行/块时撤销装饰，显露源码（Typora 式手感）。
import { EditorView, Decoration, WidgetType } from "@codemirror/view";
import { RangeSetBuilder, StateField } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import katex from "katex";
import { docContext } from "./doccontext.js";
import { t } from "./strings.js";
import { scanExtended, scanMath, scanHighlights } from "./extended.js";
import { EMOJI_MAP } from "./emoji-map.js";

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

// 语言选择白名单（下拉展示规范名；与 main.js codeLanguages 的 name 对齐，空值 = 纯文本）。
// fence 写了别名（如 ```py）时由 select 逻辑前置为当前项，选中规范名即归一化
const FENCE_LANGS = [
  "", "python", "javascript", "typescript", "json", "yaml", "bash",
  "c", "cpp", "java", "rust", "go", "swift", "sql", "html", "css",
  "dockerfile", "ruby", "perl", "lua", "r", "powershell", "toml", "ini",
  "nginx", "diff", "http", "groovy", "clojure", "haskell", "erlang", "elm",
  "julia", "octave", "fortran", "pascal", "verilog", "vhdl", "tcl",
  "vb", "protobuf", "sass", "stylus", "coffeescript", "crystal",
  "d", "xml", "mermaid",
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

// 无序列表标记（渲染美化第二阶段）：-/+/→ 按嵌套层级轮换 •/◦/▪（经典三级节奏，
// 与 Typora/GitHub 渲染一致）；替换的是源码 mark 本身，随后的空格保留原位
class ListBulletWidget extends WidgetType {
  constructor(depth) {
    super();
    this.depth = depth;
  }
  eq(o) {
    return o.depth === this.depth;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-list-bullet";
    el.textContent = ["•", "◦", "▪"][this.depth % 3];
    return el;
  }
}

// 有序列表标记：保留源码序号文本（1./1)）——所见即所得下序号即真实源码，
// 不重排；样式走 CSS（tabular-nums 对齐）
class ListNumWidget extends WidgetType {
  constructor(text) {
    super();
    this.text = text;
  }
  eq(o) {
    return o.text === this.text;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-list-num";
    el.textContent = this.text;
    return el;
  }
}

// emoji shortcode（:smile: → 😄，GitHub gemoji 全表）：码表查无此名（如时间 10:30:45
// 的 :30:）时不生成 widget，源码原样显示。双击落光标显露源码（与行内公式一致）
class EmojiWidget extends WidgetType {
  constructor(char, name) {
    super();
    this.char = char;
    this.name = name;
  }
  eq(o) {
    return o.char === this.char && o.name === this.name;
  }
  toDOM(view) {
    const el = document.createElement("span");
    el.className = "cm-emoji";
    el.textContent = this.char;
    el.title = `:${this.name}:`;
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

// 渲染态图片（FR-2.3）：光标不在行内时把 ![alt](src) 替换为真实图片；双击进入源码编辑。
// 尺寸语法（P2-1）：Obsidian `![alt|300](a.png)` / `![alt|300x200](…)` 与
// Typora `![alt](a.png =300x200)`（=300 宽、=x200 高）——解析层在 Image 节点处理，
// 此处只收解析结果。单击 → lightbox 放大查看（见 toDOM）
class ImageWidget extends WidgetType {
  constructor(src, alt, width, height) {
    super();
    this.src = src; // 已解析为 markpdf-file:// 绝对地址（尺寸后缀已剥离）
    this.alt = alt;
    this.width = width; // 数值 pt 或 undefined（保持原始尺寸）
    this.height = height;
  }
  eq(o) {
    return o.src === this.src && o.alt === this.alt && o.width === this.width && o.height === this.height;
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
      if (this.width != null) el.style.width = `${this.width}px`;
      if (this.height != null) el.style.height = `${this.height}px`;
      // 加载完成后让 CM 重测行高：异步加载前按单行估计、加载后图片撑高行，
      // CM 的 ResizeObserver 不感知内容高度变化，不主动重测会留下高度差（滚动跳变）
      el.onload = () => view.requestMeasure();
      el.onerror = () => {
        // WKWebView 偶发丢弃 markpdf-file:// 的首次子资源请求（换档重渲染后必成功
        // 的实测结论）：自动重发一次，仍失败才降级提示
        if (!el.dataset.retried) {
          el.dataset.retried = "1";
          const src = el.src;
          el.src = "";
          setTimeout(() => {
            el.src = src;
          }, 250);
          return;
        }
        const span = document.createElement("span");
        span.className = "cm-image-broken";
        span.textContent = `🖼 ${t("imageLoadFailed")}${this.alt || this.src}`;
        el.replaceWith(span);
      };
      // 单击 → lightbox 放大（P2-1b）；alt 里有尺寸语法时 caption 显示剥离后的文本
      el.addEventListener("click", (e) => {
        e.preventDefault();
        openLightbox(this.src, this.alt);
      });
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

// 图片放大查看（P2-1b）：全屏遮罩 + 居中原尺寸，滚轮缩放（0.2–5×），
// 点遮罩/ESC 关闭。挂在 body 上（脱离编辑器 DOM，不受 CM 重建影响）；
// 导出的静态 HTML 只有 innerHTML 快照，监听器不随行——交互属 App 内体验
let lightboxEl = null;
let lightboxScale = 1;
function openLightbox(src, alt) {
  closeLightbox();
  const overlay = document.createElement("div");
  overlay.className = "cm-lightbox";
  const img = document.createElement("img");
  img.src = src;
  img.alt = alt ?? "";
  img.draggable = false;
  const caption = alt ? document.createElement("div") : null;
  if (caption) {
    caption.className = "cm-lightbox-caption";
    caption.textContent = alt;
  }
  lightboxScale = 1;
  overlay.append(img);
  if (caption) overlay.append(caption);
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay || e.target === caption) closeLightbox();
  });
  overlay.addEventListener("wheel", (e) => {
    e.preventDefault();
    // 缩放步进按事件来源分档：鼠标滚轮一格明显步进；触控板捏合（ctrl+wheel，
    // 高频小步事件）用更细步长，用户定档：滚轮 6%、捏合 5%
    const perEvent = e.ctrlKey ? 1.05 : 1.06;
    const step = e.deltaY < 0 ? perEvent : 1 / perEvent;
    lightboxScale = Math.min(5, Math.max(0.2, lightboxScale * step));
    img.style.transform = `scale(${lightboxScale})`;
  }, { passive: false });
  // 双击图片：复位到 1×
  img.addEventListener("dblclick", (e) => {
    e.stopPropagation();
    lightboxScale = 1;
    img.style.transform = "scale(1)";
  });
  const onKey = (e) => {
    if (e.key === "Escape") {
      e.preventDefault();
      closeLightbox();
    }
  };
  overlay.addEventListener("keydown", onKey);
  document.body.append(overlay);
  overlay.tabIndex = -1;
  overlay.focus();
  lightboxEl = overlay;
}
function closeLightbox() {
  if (lightboxEl) {
    lightboxEl.remove();
    lightboxEl = null;
  }
}

// 文内目录块（P2-2）：单独成行的 [TOC] / [[TOC]]（大小写不敏感）→ 目录 widget：
// 标题按层级缩进，点击滚动到对应标题。目录内容随文档变化重建（key 为标题签名）
class TocWidget extends WidgetType {
  constructor(headings, key) {
    super();
    this.headings = headings; // [{level, text, line}]
    this.key = key; // 标题签名（eq 判据：标题增删改都会重建目录）
  }
  eq(o) {
    return o.key === this.key;
  }
  get estimatedHeight() {
    return this.headings.length * 27 + 18;
  }
  toDOM(view) {
    const wrap = document.createElement("div");
    wrap.className = "cm-toc";
    for (const h of this.headings) {
      const item = document.createElement("div");
      item.className = "cm-toc-item";
      item.style.paddingLeft = `${Math.max(0, h.level - 1) * 15}px`;
      item.textContent = h.text;
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        jumpToLine(view, h.line);
      });
      wrap.appendChild(item);
    }
    return wrap;
  }
  ignoreEvent() {
    return false;
  }
}

// 标题收集（与 main.js collectOutline 同口径：ATX/Setext → level/text/line）
function collectHeadingsForToc(state) {
  const items = [];
  syntaxTree(state).iterate({
    enter(node) {
      const m = /^(?:ATXHeading([1-6])|SetextHeading([12]))$/.exec(node.name);
      if (!m) return;
      const line = state.doc.lineAt(node.from);
      let text = line.text.replace(/^#{1,6}\s*/, "");
      if (m[1]) text = text.replace(/\s+#+\s*$/, "");
      text = text.trim();
      if (text) items.push({ level: m[1] ? Number(m[1]) : Number(m[2]), text, line: line.number });
      return false;
    },
  });
  return items;
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
        // 单元格内行内公式（P1-3）：KaTeX 渲染（共享全局缓存）
        if (seg.math) {
          const el = document.createElement("span");
          el.className = "cm-math-inline";
          try {
            const cacheKey = "I:" + seg.latex;
            let html = katexHtmlCache.get(cacheKey);
            if (html === undefined) {
              html = katex.renderToString(seg.latex, { displayMode: false, throwOnError: false, output: "html" });
              cachePut(katexHtmlCache, cacheKey, html, 500);
            }
            el.innerHTML = html;
          } catch {
            el.textContent = `$${seg.latex}$`; // 极端异常降级源码
          }
          cellEl.appendChild(el);
          continue;
        }
        const el = document.createElement("span");
        el.textContent = seg.text;
        if (seg.marks.includes("b")) el.style.fontWeight = "650";
        if (seg.marks.includes("i")) el.style.fontStyle = "italic";
        if (seg.marks.includes("s")) el.style.textDecoration = "line-through";
        if (seg.marks.includes("c")) el.classList.add("cm-inline-code");
        // classList.add 累加：单元格同时是 code+link 时两类都要保留（className 二次赋值会覆盖）
        if (seg.marks.includes("a")) el.classList.add("cm-link");
        if (seg.hl) el.classList.add("cm-highlight");
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

// Callout 高亮块（P1-2，GitHub Alerts / Obsidian 双语法）：按行着色（保留块内富文本渲染），
// [!type] 标记替换为「图标+标题」徽章。Obsidian 众多类型名折叠到 6 个规范色系（GitHub 五色 + 引用灰）
const CALLOUT_TYPES = (() => {
  const m = {};
  const put = (canon, keys) => keys.forEach((k) => (m[k] = canon));
  put("note", ["note", "info", "todo", "abstract", "summary", "tldr"]);
  put("tip", ["tip", "hint", "success", "check", "done", "example"]);
  put("important", ["important"]);
  put("warning", ["warning", "attention", "question", "help", "faq"]);
  put("caution", ["caution", "danger", "error", "bug", "failure", "fail", "missing"]);
  put("quote", ["quote", "cite"]);
  return m;
})();

// 规范类型的图标与默认标题（自定义标题跟在 ] 后时优先生效）
const CALLOUT_META = {
  note: { icon: "ℹ️", title: "备注" },
  tip: { icon: "💡", title: "提示" },
  important: { icon: "❗", title: "重要" },
  warning: { icon: "⚠️", title: "警告" },
  caution: { icon: "🛑", title: "危险" },
  quote: { icon: "💬", title: "引用" },
};

class CalloutBadgeWidget extends WidgetType {
  constructor(type, title) {
    super();
    this.type = type; // 规范类型名
    this.title = title; // 自定义标题；null = 用默认标题
  }
  eq(o) {
    return o.type === this.type && o.title === this.title;
  }
  toDOM() {
    const meta = CALLOUT_META[this.type];
    const el = document.createElement("span");
    el.className = "cm-callout-badge";
    el.textContent = `${meta.icon} ${this.title ?? meta.title}`;
    return el;
  }
}

// Mermaid 图表（P1-4 懒加载）：```mermaid 块整体替换为图表。渲染库 dist/mermaid-render.js
// （~2MB 独立产物）由首个 mermaid widget 注入 <script> 按需加载，不拖慢启动。
// 渲染失败（语法错误/库加载失败）降级显示源码；主题跟随明暗。
let mermaidScriptLoading = null;
function ensureMermaid() {
  if (window.__markpdfMermaid) return Promise.resolve();
  if (!mermaidScriptLoading) {
    mermaidScriptLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      // App 内走 markpdf-file:// 协议供给（file:// 页面动态加载本地脚本被 WebKit
      // 安全策略拦截）；浏览器调试用相对路径
      s.src = docContext.mermaidScriptURL || "dist/mermaid-render.js";
      s.onload = () => resolve();
      s.onerror = () => {
        mermaidScriptLoading = null; // 允许后续重试
        reject(new Error("mermaid script load failed"));
      };
      document.head.append(s);
    });
  }
  return mermaidScriptLoading;
}

let mermaidRenderSeq = 0;
class MermaidWidget extends WidgetType {
  constructor(definition, source) {
    super();
    this.definition = definition; // fence 内图表定义文本
    this.source = source; // 整块源码（eq 去重 + 降级显示）
  }
  eq(o) {
    return o.source === this.source;
  }
  get estimatedHeight() {
    const cached = widgetHeightCache.get("g:" + this.source);
    if (cached) return cached;
    const rows = this.definition.split("\n").length;
    return rows * 26 + 40; // 粗估：行数×行高 + 边距；实测后由缓存接管
  }
  toDOM(view) {
    const el = document.createElement("div");
    el.className = "cm-mermaid";
    el.textContent = "⏳ 图表渲染中…";
    rememberHeight("g:" + this.source, el);
    ensureMermaid()
      .then(async () => {
        const mermaid = window.__markpdfMermaid;
        if (!el.isConnected) return;
        try {
          mermaid.initialize({
            theme: document.documentElement.dataset.theme === "dark" ? "dark" : "default",
          });
          const { svg } = await mermaid.render(`markpdf-mmd-${++mermaidRenderSeq}`, this.definition);
          if (!el.isConnected) return;
          el.innerHTML = svg;
          el.classList.add("cm-mermaid-done");
          view.requestMeasure(); // SVG 真实高度替代估计
        } catch (err) {
          // 语法错误：GitHub 同款处置——友好文案 + 错误详情（pre-wrap 换行显示，
          // 便于用户报障时直接带出真实原因）
          if (!el.isConnected) return;
          el.classList.add("cm-mermaid-error");
          el.textContent = `⚠️ 图表语法错误（点击进入源码编辑）\n${(err && err.message) || err}`;
        }
      })
      .catch(() => {
        if (!el.isConnected) return;
        el.classList.add("cm-mermaid-error");
        el.textContent = this.source;
      });
    // 单击落光标回源码编辑（块级公式同款）
    el.addEventListener("mousedown", (e) => {
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

// 单元格内联内容 → 带样式片段（marks: b/i/s/c/a；hl=高亮底；math=行内公式）。
// 公式/高亮由单元格级正则扫描补充（lezer 不解析单元格内 $..$ / ==..==，
// 全文档扫描又把表格整体排除——此前单元格内公式只能显示源码，P1-3 补齐）
function cellSegments(state, cell) {
  const segs = [];
  const emit = (f, t, marks) => {
    if (f < t) segs.push({ from: f, to: t, text: state.doc.sliceString(f, t), marks });
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
  return splitCellRanges(segs, state.doc.sliceString(cell.from, cell.to), cell.from);
}

// 把单元格内行内公式/高亮范围切进片段流：
// plain 片段按范围裁剪（保留原有 b/i/s/c/a 标记；高亮段叠加 hl），
// 公式段整体替换为 KaTeX（内部 marks 忽略——内容是 LaTeX 源），
// 高亮的 == 定界符按 skip 段丢弃。高亮与公式相交时先到先得
//（扫描器本身已把公式范围内的 == 排除，此处为兜底）
function splitCellRanges(segs, text, base) {
  const maths = scanMath(text)
    .filter((m) => !m.displayMode) // 单元格内只取行内公式（块级 $$ 不适合塞进表格）
    .map((m) => ({ from: base + m.from, to: base + m.to, latex: m.latex, kind: "math" }));
  const hls = [];
  for (const h of scanHighlights(
    text,
    maths.map((m) => ({ from: m.from - base, to: m.to - base }))
  )) {
    hls.push({ from: base + h.openFrom, to: base + h.openTo, kind: "skip" });
    hls.push({ from: base + h.contentFrom, to: base + h.contentTo, kind: "hl" });
    hls.push({ from: base + h.closeFrom, to: base + h.closeTo, kind: "skip" });
  }
  if (!maths.length && !hls.length) return segs;
  const marks = [...maths, ...hls].sort((a, b) => a.from - b.from);
  const clip = (from, to, hl) => {
    for (const s of segs) {
      const f = Math.max(s.from, from);
      const t = Math.min(s.to, to);
      if (f >= t) continue;
      const out = { text: s.text.slice(f - s.from, t - s.from), marks: s.marks };
      if (hl) out.hl = true;
      result.push(out);
    }
  };
  const result = [];
  let cursor = base;
  for (const r of marks) {
    if (r.from < cursor) continue;
    clip(cursor, r.from, false);
    if (r.kind === "math") result.push({ math: true, latex: r.latex, marks: "" });
    else if (r.kind === "hl") clip(r.from, r.to, true);
    cursor = r.to; // skip：直接越过（不产出片段）
  }
  clip(cursor, base + text.length, false);
  return result;
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

  // 代码块范围（下方空行压缩判定用；iterate 内收集）
  const codeRanges = [];

  // [TOC] / [[TOC]] 目录块（P2-2）：需在树遍历前处理——`[TOC]` 被 lezer 解析为
  // Link（两 LinkMark），整行 block replace 与其隐藏装饰相交是 CM 禁止项，
  // 先登记 extReplaces 抑制。文档无标题时保持源码不渲染
  const tocHeadings = collectHeadingsForToc(state);
  if (tocHeadings.length > 0) {
    const tocKey = tocHeadings.map((h) => `${h.level}:${h.text}@${h.line}`).join("|");
    const tocRe = /^\s*\[?\[TOC\]\]?\s*$/i;
    for (let n = 1; n <= state.doc.lines; n++) {
      const line = state.doc.line(n);
      if (!tocRe.test(line.text) || isLineActive(line.from)) continue;
      decos.push({
        from: line.from,
        to: line.to,
        deco: Decoration.replace({ widget: new TocWidget(tocHeadings, tocKey), block: true }),
      });
      extReplaces.push({ from: line.from, to: line.to });
    }
  }

  syntaxTree(state).iterate({
    enter(node) {
      const { name, from, to } = node;

      // 代码块范围收集（段落空行压缩需跳过：代码区内的空行是内容，行高不可变）
      if (name === "FencedCode" || name === "IndentedCode") {
        codeRanges.push({ from, to });
      }

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

        case "ListMark": {
          // 列表标记渲染（美化第二阶段）：任务项的 - 连同尾随空格整体隐藏
          //（复选框自带间距，Typora 同款无前置符号）；普通项替换为 bullet/序号样式 widget。
          // 光标在本行显露源码
          if (isLineActive(from)) return false;
          const rest = state.doc.sliceString(to, state.doc.lineAt(to).to);
          if (/^\s*\[[ xX]\]/.test(rest)) {
            const end = rest[0] === " " ? to + 1 : to;
            addHide(from, end);
            return false;
          }
          const listNode = node.node.parent?.parent; // ListMark → ListItem → BulletList/OrderedList
          if (listNode?.name === "OrderedList") {
            addWidgetReplace(from, to, new ListNumWidget(state.doc.sliceString(from, to)));
          } else {
            let depth = 0;
            for (let p = node.node.parent; p; p = p.parent) {
              if (p.name === "ListItem") depth++;
            }
            addWidgetReplace(from, to, new ListBulletWidget(depth - 1));
          }
          return false;
        }

        case "Subscript":
        case "Superscript": {
          // 上下标（GFM 扩展，lezer 默认解析）：内容整体上/下标样式，定界符 ~ ^ 隐藏
          addMark(from, to, name === "Subscript" ? "cm-sub" : "cm-sup");
          if (!isLineActive(from)) {
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.name === name + "Mark") addHide(c.from, c.to);
            }
          }
          return false;
        }

        case "Emoji": {
          // emoji shortcode（:smile: → 😄，GitHub gemoji 全表）；码表查无（如时间串 :30:）
          // 不生成 widget，源码原样。光标在场显露源码
          if (!isLineActive(from)) {
            const short = state.doc.sliceString(from + 1, to - 1);
            const char = EMOJI_MAP.get(short);
            if (char) addWidgetReplace(from, to, new EmojiWidget(char, short));
          }
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
              let alt = (/^!\[([^\]]*)\]/.exec(raw) || [])[1] ?? "";
              // 尺寸语法（P2-1）：先剥 Typora 的 URL 尾缀 ` =WxH`，再剥 Obsidian 的 alt 尾缀 `|W[xH]`
              let width;
              let height;
              const tm = /\s+=\s*(\d+)?x?(\d+)?\s*$/.exec(src);
              if (tm) {
                src = src.slice(0, tm.index);
                if (tm[1]) width = Number(tm[1]);
                if (tm[2]) height = Number(tm[2]);
              }
              const om = /\|(\d+)(?:x(\d+))?\s*$/.exec(alt);
              if (om) {
                alt = alt.slice(0, om.index).trimEnd();
                width = Number(om[1]);
                if (om[2]) height = Number(om[2]);
              }
              addWidgetReplace(from, to, new ImageWidget(resolveImageURL(src), alt, width, height));
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

        case "Blockquote": {
          // 注意节点名大小写：lezer 是 "Blockquote"（小写 q）——曾写成 BlockQuote
          // 导致引用块行样式从未生效的存量 bug，随 P1-2 一并修复
          const firstLine = state.doc.lineAt(from);
          const lastLineNum = state.doc.lineAt(to).number;
          // Callout 高亮块（P1-2）：首行 > [!type]（大小写不敏感；GitHub Alerts / Obsidian 通用）
          const cm = /^>\s*\[!(\w+)\]\s*(.*)$/.exec(firstLine.text);
          const canon = cm ? CALLOUT_TYPES[cm[1].toLowerCase()] : null;
          if (canon) {
            for (let n = firstLine.number; n <= lastLineNum; n++) {
              let cls = `cm-callout cm-callout-${canon}`;
              if (n === firstLine.number) cls += " cm-callout-first";
              if (n === lastLineNum) cls += " cm-callout-last";
              addLine(state.doc.line(n).from, cls);
            }
            // [!type] 标记 → 徽章 widget（自定义标题保留在其后的源文本里）；光标在场显源码。
            // 徽章范围先登记 extReplaces：[!type] 会被 lezer 误解析为 Link（两个 LinkMark），
            // 其隐藏装饰与本 replace 相交是 CM 禁止项。return 继续（非 false）：QuoteMark 等仍生效
            if (!isLineActive(firstLine.from)) {
              const markFrom = firstLine.from + firstLine.text.indexOf("[!");
              const markTo = markFrom + cm[1].length + 3; // [!xxx] 共 len+3 字符
              const customTitle = cm[2].trim();
              extReplaces.push({ from: markFrom, to: markTo });
              addWidgetReplace(markFrom, markTo, new CalloutBadgeWidget(canon, customTitle || null));
            }
            return;
          }
          for (let n = firstLine.number; n <= lastLineNum; n++) addLine(state.doc.line(n).from, "cm-quote-line");
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
          // 取语言标识
          let lang = "";
          for (let c = node.node.firstChild; c; c = c.nextSibling) {
            if (c.name === "CodeInfo") lang = state.doc.sliceString(c.from, c.to).trim().toLowerCase();
          }
          const multi = lastLine.number > firstLine.number;
          const active = isRangeActive(from, to);
          // mermaid 图表（P1-4）：光标离块即整体替换为渲染图（懒加载库，见 MermaidWidget）
          if (lang === "mermaid" && multi && !active) {
            const parts = [];
            for (let n = firstLine.number + 1; n < lastLine.number; n++) parts.push(state.doc.line(n).text);
            const source = state.doc.sliceString(firstLine.from, lastLine.to);
            decos.push({
              from: firstLine.from,
              to: lastLine.to,
              deco: Decoration.replace({ widget: new MermaidWidget(parts.join("\n"), source), block: true }),
            });
            extReplaces.push({ from: firstLine.from, to: lastLine.to });
            return false;
          }
          for (let n = firstLine.number; n <= lastLine.number; n++) {
            // 首/末行附加类：盒子圆角与上下内边距（编辑态 fence 行可见时也是完整盒子）
            let cls = "cm-codeblock-line";
            if (n === firstLine.number) cls += " cm-codeblock-first";
            if (n === lastLine.number) cls += " cm-codeblock-last";
            addLine(state.doc.line(n).from, cls);
          }
          if (!active && multi) {
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

  // 段落间距体系（美化第二阶段）：块之间的空行行高走 --editor-para-gap
  //（GitHub/Typora 式紧凑节奏，设置面板「段距」可调）。代码块/公式块内的空行
  // 是内容不参与；被块级 widget 整体替换的范围（表格等）内也无空行，无需排除
  const inBlockContent = (pos) =>
    codeRanges.some((r) => pos >= r.from && pos < r.to) ||
    extReplaces.some((r) => pos >= r.from && pos < r.to);
  for (let n = 1; n <= state.doc.lines; n++) {
    const line = state.doc.line(n);
    if (line.text.trim() === "" && !inBlockContent(line.from)) {
      addLine(line.from, "cm-sep-line");
    }
  }

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
