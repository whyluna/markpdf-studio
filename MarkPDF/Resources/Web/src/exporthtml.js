// 导出独立可分享 HTML（FR-2.9）
// 原理：用阅读模式配置（wysiwyg alwaysRender）离屏重渲染当前文档，
// 取 .cm-content 的 innerHTML，连同页面上的样式（内联 <style> + editor.css 链接）
// 包成独立 HTML 文档。渲染逻辑依赖 DOM/CM，纯函数部分（标题提取、图片重写、
// HTML 包装）单独导出便于 vitest 单测。
import { EditorView } from "@codemirror/view";
import { EditorState } from "@codemirror/state";

/* ---------- 标题提取 ---------- */

// 行内标记 → 纯文本（用于 <title>）：去强调/代码/高亮/删除线标记，[text](url) → text
function plainText(md) {
  return md
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__|\*|_|~~|==|`)/g, "")
    .trim();
}

/**
 * 取文档第一个 ATX / Setext 标题文本作为导出标题（跳过代码块），无标题用默认名
 */
export function extractTitle(docText) {
  const lines = docText.split("\n");
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*(`{3,}|~{3,})/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const atx = /^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/.exec(line);
    if (atx) return plainText(atx[1]) || "Markdown 导出";
    // Setext：文本行 + === / --- 下划线
    if (line.trim() && i + 1 < lines.length && /^\s{0,3}(=+|-+)\s*$/.test(lines[i + 1])) {
      return plainText(line) || "Markdown 导出";
    }
  }
  return "Markdown 导出";
}

/* ---------- 图片链接重写 ---------- */

/**
 * markpdf-file://host/abs/path（WKWebView 自定义协议绝对地址）→ 可分享地址：
 * 位于 baseURL 目录内 → 相对路径；目录外 → file:///abs/path 绝对形式；
 * 其余 src（相对路径 / http(s) / data: 等）原样保留。
 */
export function rewriteImgSrc(src, baseURL) {
  if (!src || !src.startsWith("markpdf-file://")) return src;
  let abs;
  try {
    abs = new URL(src).pathname;
  } catch {
    return src;
  }
  try {
    if (baseURL) {
      let basePath = new URL(baseURL).pathname;
      if (!basePath.endsWith("/")) basePath += "/";
      if (abs.startsWith(basePath) && abs.length > basePath.length) {
        return abs.slice(basePath.length);
      }
    }
  } catch {
    return src;
  }
  return "file://" + abs;
}

/* ---------- 样式收集与 HTML 包装 ---------- */

// 收集页面样式：内联 <style> 文本（含主题变量/装饰样式与 CM 注入的主题样式）+ 外部样式表
// 绝对地址（el.href 属性：App 内为 file:// bundle 路径；getAttribute 是源码里的相对路径，不能用）
export function collectPageStyles(doc = document) {
  const inlineStyles = [...doc.querySelectorAll("style")].map((el) => el.textContent ?? "");
  const cssHrefs = [...doc.querySelectorAll('link[rel="stylesheet"]')]
    .map((el) => el.href)
    .filter(Boolean);
  return { inlineStyles, cssHrefs };
}

const escapeHTML = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/**
 * 包成独立 HTML 文档。cm-editor/cm-scroller/cm-content 外壳让收集到的
 * CM 主题与装饰样式（.cm-content 的 maxWidth/padding 等）在导出页中生效；
 * classes 为临时 view 的真实类名（含主题 hash 类，否则 CM 注入的主题样式全部落空——
 * 此前裸 cm-editor 外壳导致导出回退到 CM 默认 monospace 主题）。
 */
export function buildExportHTML({ title, theme, inlineStyles, cssHrefs, contentHTML, classes }) {
  const styles = inlineStyles.map((s) => `<style>\n${s}\n</style>`).join("\n");
  const links = cssHrefs.map((h) => `<link rel="stylesheet" href="${escapeHTML(h)}">`).join("\n");
  const editorClass = classes?.editor || "cm-editor";
  const scrollerClass = classes?.scroller || "cm-scroller";
  const contentClass = classes?.content || "cm-content";
  // 导出页整页流式布局（编辑器壳是内滚动容器，导出文档应整页滚动，否则 body 只有一屏高）
  const exportOverrides = `
html, body { margin: 0; height: auto !important; }
.cm-editor, .cm-scroller { height: auto !important; overflow-y: visible !important; }
.cm-scroller { overflow-x: auto; }
`;
  return `<!DOCTYPE html>
<html data-theme="${escapeHTML(theme)}">
<head>
<meta charset="utf-8">
<title>${escapeHTML(title)}</title>
${styles}
${links}
<style>${exportOverrides}</style>
</head>
<body>
<div class="${escapeHTML(editorClass)}"><div class="${escapeHTML(scrollerClass)}"><div class="${escapeHTML(contentClass)}">
${contentHTML}
</div></div></div>
</body>
</html>`;
}

/* ---------- 离屏渲染 ---------- */

// rAF 兜底（jsdom 等无 rAF 的环境退化为宏任务）
const nextFrame =
  typeof requestAnimationFrame === "function"
    ? requestAnimationFrame
    : (f) => setTimeout(f, 0);

/**
 * 离屏重渲染文档为 .cm-content 的 innerHTML。
 * 关键机制（CM 源码实锤）：CM 只测量「在窗口内」的编辑器（measure 首行判
 * inView/scrollTarget/inWindow，不可见直接 return 0），且视口最多超出可见区
 * 2×VP.Margin——所以宿主必须在屏（不可见即可，visibility:hidden）且滚动器
 * 可滚动、高度 ≥ 全文高度；完全离屏（left:-100000px）或滚动器不可滚动
 * （height:auto/overflow:visible 退化给窗口滚动）都会导致视口不增长、导出截断。
 * 返回渲染内容、外壳类名（主题 hash 类，导出排版与编辑态一致的关键）与页面样式
 * （在临时 view 销毁前收集，style-mod 卸载后其样式会从 head 移除）。
 */
export function renderExportContent(docText, extensions, baseURL) {
  return new Promise((resolve) => {
    const holder = document.createElement("div");
    holder.setAttribute("aria-hidden", "true");
    // 在屏但不可见（CM 不测量窗口外编辑器）。初始高度仅首屏量级——
    // 必须让内容高度 > 滚动器高度使其「可滚动」（滚动器 ≤ 内容时滚动父级
    // 会退化为窗口，视口随之坍缩到窗口大小，导出截断；CM 源码实锤）
    holder.style.cssText = "position:fixed;left:0;top:0;width:900px;z-index:-100;visibility:hidden";
    holder.style.height = "5000px";
    document.body.appendChild(holder);
    const view = new EditorView({
      parent: holder,
      state: EditorState.create({ doc: docText, extensions }),
    });
    // CM「打印模式」（官方机制，beforeprint 事件同款）：pixelViewport 取全文范围、
    // 视口不再受限——普通渲染态 CM 视口只算「窗口内可见部分」，任何离屏/超高滚动器
    // 花招都无法让它覆盖全文（用户长文档导出截断的根因）
    view.viewState.printing = true;
    view.measure();

    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      // 图片链接重写：markpdf-file:// 绝对地址 → 相对/ file:// 可分享地址
      for (const img of view.dom.querySelectorAll("img")) {
        const src = img.getAttribute("src");
        const rewritten = rewriteImgSrc(src, baseURL);
        if (rewritten !== src) img.setAttribute("src", rewritten);
      }
      const result = {
        html: view.contentDOM.innerHTML,
        classes: {
          editor: view.dom.className,
          scroller: view.scrollDOM.className,
          content: view.contentDOM.className,
        },
        styles: collectPageStyles(),
      };
      view.destroy();
      holder.remove();
      resolve(result);
    };

    // 打印模式下一次同步测量视口即覆盖全文；留逐帧复核与 3s 兜底（绝不 hang）
    const start = Date.now();
    const check = () => {
      nextFrame(() => {
        view.requestMeasure();
        if (view.viewport.to >= view.state.doc.length || Date.now() - start > 3000) {
          finish();
        } else {
          check();
        }
      });
    };
    check();
  });
}

/**
 * 导出当前文档：{ title, html }
 * @param extensions 阅读模式配置（由 main.js 传入，与主实例共用基础扩展）
 */
export async function buildExport({ docText, baseURL, extensions, theme }) {
  const { html: contentHTML, classes, styles } = await renderExportContent(docText, extensions, baseURL);
  const title = extractTitle(docText);
  return {
    title,
    html: buildExportHTML({
      title,
      theme,
      inlineStyles: styles.inlineStyles,
      cssHrefs: styles.cssHrefs,
      contentHTML,
      classes,
    }),
  };
}
