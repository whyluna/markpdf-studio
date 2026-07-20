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

// 收集页面样式：内联 <style> 文本（含主题变量/装饰样式与 CM 注入的主题样式）+ 外部样式表 href
export function collectPageStyles(doc = document) {
  const inlineStyles = [...doc.querySelectorAll("style")].map((el) => el.textContent ?? "");
  const cssHrefs = [...doc.querySelectorAll('link[rel="stylesheet"]')]
    .map((el) => el.getAttribute("href"))
    .filter(Boolean);
  return { inlineStyles, cssHrefs };
}

const escapeHTML = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/**
 * 包成独立 HTML 文档。cm-editor/cm-scroller/cm-content 外壳让收集到的
 * CM 主题与装饰样式（.cm-content 的 maxWidth/padding 等）在导出页中生效。
 */
export function buildExportHTML({ title, theme, inlineStyles, cssHrefs, contentHTML }) {
  const styles = inlineStyles.map((s) => `<style>\n${s}\n</style>`).join("\n");
  const links = cssHrefs.map((h) => `<link rel="stylesheet" href="${escapeHTML(h)}">`).join("\n");
  return `<!DOCTYPE html>
<html data-theme="${escapeHTML(theme)}">
<head>
<meta charset="utf-8">
<title>${escapeHTML(title)}</title>
${styles}
${links}
</head>
<body>
<div class="cm-editor"><div class="cm-scroller"><div class="cm-content">
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
 * CM 只渲染视口内容：宿主给一个足够大的显式高度，等测量循环生效后检查
 * view.viewport 是否覆盖全文，未覆盖则加倍高度重试（隐藏容器 clientHeight 为 0，
 * 不显式给高则长文档会被截断）。渲染完成后销毁临时 view 并移除宿主。
 */
export function renderExportContent(docText, extensions, baseURL) {
  return new Promise((resolve) => {
    const holder = document.createElement("div");
    holder.setAttribute("aria-hidden", "true");
    holder.style.cssText = "position:absolute;left:-100000px;top:0;width:900px;overflow:hidden";
    let height = Math.max(20000, docText.split("\n").length * 100 + 5000);
    holder.style.height = height + "px";
    document.body.appendChild(holder);
    const view = new EditorView({
      parent: holder,
      state: EditorState.create({ doc: docText, extensions }),
    });

    const finish = () => {
      // 图片链接重写：markpdf-file:// 绝对地址 → 相对/ file:// 可分享地址
      for (const img of view.dom.querySelectorAll("img")) {
        const src = img.getAttribute("src");
        const rewritten = rewriteImgSrc(src, baseURL);
        if (rewritten !== src) img.setAttribute("src", rewritten);
      }
      const html = view.contentDOM.innerHTML;
      view.destroy();
      holder.remove();
      resolve(html);
    };

    let attempts = 0;
    const pump = () => {
      nextFrame(() => {
        if (attempts < 8 && view.viewport.to < view.state.doc.length) {
          attempts++;
          height *= 2;
          holder.style.height = height + "px";
          pump();
        } else {
          finish();
        }
      });
    };
    pump();
  });
}

/**
 * 导出当前文档：{ title, html }
 * @param extensions 阅读模式配置（由 main.js 传入，与主实例共用基础扩展）
 */
export async function buildExport({ docText, baseURL, extensions, theme }) {
  const { inlineStyles, cssHrefs } = collectPageStyles();
  const contentHTML = await renderExportContent(docText, extensions, baseURL);
  const title = extractTitle(docText);
  return { title, html: buildExportHTML({ title, theme, inlineStyles, cssHrefs, contentHTML }) };
}
