// 所见即所得装饰层（FR-2.1）
// 原理：解析 lezer markdown 语法树，对「光标不在场」的语法标记施加隐藏/替换装饰，
// 对块级结构施加行样式；光标进入对应行/块时撤销装饰，显露源码（Typora 式手感）。
import { EditorView, ViewPlugin, Decoration, WidgetType } from "@codemirror/view";
import { RangeSetBuilder } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";

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

/* ---------- 装饰构建 ---------- */

function buildDecorations(view, alwaysRender) {
  const state = view.state;
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

        case "Link":
        case "Image": {
          // 隐藏 [ ] ( ) 与 URL，仅保留带样式的链接文字
          addMark(from, to, name === "Link" ? "cm-link" : "cm-image");
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
            addLine(state.doc.line(n).from, "cm-codeblock-line");
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
          // v0.1：等宽 + 源码可见；表格所见即所得（Typora 式）排期 FR-2.3 后续迭代
          const first = state.doc.lineAt(from).number;
          const last = state.doc.lineAt(to).number;
          for (let n = first; n <= last; n++) addLine(state.doc.line(n).from, "cm-table-line");
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
 * 所见即所得插件
 * @param {boolean} alwaysRender true=阅读模式：全部渲染、永不显露源码
 */
export function wysiwyg(alwaysRender) {
  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = buildDecorations(view, alwaysRender);
      }
      update(u) {
        if (
          u.docChanged ||
          u.selectionSet ||
          u.viewportChanged ||
          syntaxTree(u.state) !== syntaxTree(u.startState)
        ) {
          this.decorations = buildDecorations(u.view, alwaysRender);
        }
      }
    },
    { decorations: (v) => v.decorations }
  );
}
