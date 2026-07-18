// 所见即所得装饰层（FR-2.1）
// 原理：解析 lezer markdown 语法树，对「光标不在场」的语法标记施加隐藏/替换装饰，
// 对块级结构施加行样式；光标进入对应行/块时撤销装饰，显露源码（Typora 式手感）。
import { EditorView, Decoration, WidgetType } from "@codemirror/view";
import { RangeSetBuilder, StateField } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { docContext } from "./doccontext.js";

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

// 代码块起始 fence 行 → 语言徽标
class FenceBadgeWidget extends WidgetType {
  constructor(lang) {
    super();
    this.lang = lang;
  }
  eq(o) {
    return o.lang === this.lang;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-fence-badge";
    el.textContent = this.lang || "code";
    return el;
  }
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

// 渲染态图片（FR-2.3）：光标不在行内时把 ![alt](src) 替换为真实图片
class ImageWidget extends WidgetType {
  constructor(src, alt) {
    super();
    this.src = src; // 已解析为 markpdf-file:// 绝对地址
    this.alt = alt;
  }
  eq(o) {
    return o.src === this.src && o.alt === this.alt;
  }
  toDOM() {
    if (!this.src) {
      const span = document.createElement("span");
      span.className = "cm-image-broken";
      span.textContent = `🖼 ${this.alt || "图片"}（草稿暂不支持相对路径图片）`;
      return span;
    }
    const img = document.createElement("img");
    img.className = "cm-rendered-image";
    img.src = this.src;
    img.alt = this.alt;
    img.onerror = () => {
      const span = document.createElement("span");
      span.className = "cm-image-broken";
      span.textContent = `🖼 图片加载失败：${this.alt || this.src}`;
      img.replaceWith(span);
    };
    return img;
  }
}

// 渲染态表格（FR-2.3）：光标在表格外时整体替换为 HTML 表格；点击进入源码编辑
class TableWidget extends WidgetType {
  constructor(model, source) {
    super();
    this.model = model; // { header: [segs], rows: [[segs]], rowStarts: [pos] }
    this.source = source; // 表格源码文本，用于 eq 去重
  }
  eq(o) {
    return o.source === this.source;
  }
  toDOM(view) {
    const wrap = document.createElement("div");
    wrap.className = "cm-table-widget";
    const table = document.createElement("table");

    const appendSegs = (cellEl, segs) => {
      for (const seg of segs) {
        const el = document.createElement("span");
        el.textContent = seg.text;
        if (seg.marks.includes("b")) el.style.fontWeight = "650";
        if (seg.marks.includes("i")) el.style.fontStyle = "italic";
        if (seg.marks.includes("s")) el.style.textDecoration = "line-through";
        if (seg.marks.includes("c")) el.className = "cm-inline-code";
        if (seg.marks.includes("a")) el.className = "cm-link";
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
    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const tr = e.target.closest("tr");
      const idx = tr ? Number(tr.dataset.row) : this.model.rowStarts.length - 1;
      const pos = this.model.rowStarts[Math.min(idx, this.model.rowStarts.length - 1)];
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

// 遍历 Table 节点，提取表头/数据行单元格与各行源码起始偏移；解析失败返回 null（降级源码样式）
function buildTableModel(state, tableNode) {
  const header = [];
  const rows = [];
  const rowStarts = [];
  for (let child = tableNode.firstChild; child; child = child.nextSibling) {
    if (child.name !== "TableHeader" && child.name !== "TableRow") continue;
    const cells = [];
    for (let cell = child.firstChild; cell; cell = cell.nextSibling) {
      if (cell.name === "TableCell") cells.push(cellSegments(state, cell));
    }
    rowStarts.push(state.doc.lineAt(child.from).from);
    if (child.name === "TableHeader") header.push(...cells);
    else rows.push(cells);
  }
  if (header.length === 0) return null;
  return { header, rows, rowStarts };
}

/* ---------- 装饰构建 ---------- */

function buildDecorations(state, alwaysRender) {
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

  // active 判定：阅读模式（alwaysRender）下永不显露源码
  const isLineActive = (pos) => !alwaysRender && lineActive(state, pos);
  const isRangeActive = (from, to) => !alwaysRender && rangeActive(state, from, to);

  syntaxTree(state).iterate({
    enter(node) {
      const { name, from, to } = node;

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
  return StateField.define({
    create(state) {
      return buildDecorations(state, alwaysRender);
    },
    update(deco, tr) {
      if (tr.docChanged || tr.selection || syntaxTree(tr.state) !== syntaxTree(tr.startState)) {
        return buildDecorations(tr.state, alwaysRender);
      }
      return deco;
    },
    provide: (field) => EditorView.decorations.from(field),
  });
}
