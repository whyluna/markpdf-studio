// 扩展 Markdown 语法扫描（FR-2.4）：KaTeX 数学公式、高亮 ==x==、脚注 [^a]
// 纯函数模块：不依赖 DOM / CodeMirror，输入文档文本与排除范围（代码区等），输出匹配范围，
// 便于 vitest 单测。排除规则与 wysiwyg.js 的 replace 装饰冲突规避一一对应：
//   - 数学公式整体不得与排除范围相交；
//   - 高亮仅两侧 == 标记不得落在排除范围内（内容区允许包含代码/公式）；
//   - 脚注引用整体不得与排除范围相交，且不得紧跟 !（图片 alt）；
//   - 脚注定义标记不得落在排除范围内。

/* ---------- 工具 ---------- */

// pos 处字符是否被反斜杠转义（前面连续奇数个 \）
function escaped(text, pos) {
  let n = 0;
  for (let i = pos - 1; i >= 0 && text[i] === "\\"; i--) n++;
  return n % 2 === 1;
}

// [from, to) 是否与任一排除范围相交
function intersects(ranges, from, to) {
  for (const r of ranges) {
    if (from < r.to && to > r.from) return true;
  }
  return false;
}

/* ---------- 数学公式：$$ 块级优先于 $ 行内 ---------- */

/**
 * @returns [{from, to, latex, displayMode}] latex 为 $ 之间的内容
 */
export function scanMath(text, excludeRanges = []) {
  const maths = [];
  let i = 0;
  while (i < text.length) {
    if (text[i] !== "$" || escaped(text, i)) {
      i++;
      continue;
    }
    if (text[i + 1] === "$") {
      // 块级 $$...$$（可多行）：向后找最近的 $$
      let j = i + 2;
      let found = -1;
      while (j < text.length) {
        if (text[j] === "\\") {
          j += 2;
          continue;
        }
        if (text[j] === "$" && text[j + 1] === "$") {
          found = j;
          break;
        }
        j++;
      }
      if (found >= 0) {
        const latex = text.slice(i + 2, found);
        if (latex.trim() && !intersects(excludeRanges, i, found + 2)) {
          maths.push({ from: i, to: found + 2, latex, displayMode: true });
        }
        i = found + 2;
      } else {
        i += 2;
      }
      continue;
    }
    // 行内 $...$：开 $ 后不能紧跟空白，内容不跨行
    const open = text[i + 1];
    if (open === undefined || /\s/.test(open)) {
      i++;
      continue;
    }
    let j = i + 1;
    let matched = false;
    while (j < text.length) {
      const ch = text[j];
      if (ch === "\\") {
        j += 2;
        continue;
      }
      if (ch === "\n") break;
      if (ch === "$") {
        // 闭 $ 前不能是空白；后不能紧跟数字（防 $5,$5 货币误判）
        if (!/\s/.test(text[j - 1]) && !/\d/.test(text[j + 1] ?? "")) {
          if (!intersects(excludeRanges, i, j + 1)) {
            maths.push({ from: i, to: j + 1, latex: text.slice(i + 1, j), displayMode: false });
          }
          i = j + 1;
          matched = true;
          break;
        }
      }
      j++;
    }
    if (!matched) i++;
  }
  return maths;
}

/* ---------- 高亮 ==x==（不跨行） ---------- */

/**
 * @returns [{from, to, openFrom, openTo, contentFrom, contentTo, closeFrom, closeTo}]
 */
export function scanHighlights(text, excludeRanges = []) {
  const highlights = [];
  let i = 0;
  while (i < text.length) {
    if (text[i] !== "=" || text[i + 1] !== "=") {
      i++;
      continue;
    }
    // 开 == 后不能紧跟空白或 =
    const open = text[i + 2];
    if (open === undefined || /[\s=]/.test(open)) {
      i += 2;
      continue;
    }
    // 找最近的 == 作为关闭候选；候选非法则整个开标记作废（内容不允许跨越 ==，边界确定）
    let j = i + 2;
    let advanced = false;
    while (j < text.length) {
      const ch = text[j];
      if (ch === "\n") break;
      if (ch === "=" && text[j + 1] === "=") {
        // 闭 == 前不能是空白或 =，后不能紧跟 =
        if (!/[\s=]/.test(text[j - 1]) && text[j + 2] !== "=") {
          if (!intersects(excludeRanges, i, i + 2) && !intersects(excludeRanges, j, j + 2)) {
            highlights.push({
              from: i,
              to: j + 2,
              openFrom: i,
              openTo: i + 2,
              contentFrom: i + 2,
              contentTo: j,
              closeFrom: j,
              closeTo: j + 2,
            });
          }
          i = j + 2;
          advanced = true;
        }
        break;
      }
      j++;
    }
    if (!advanced) i += 2;
  }
  return highlights;
}

/* ---------- 脚注：定义行 [^a]: ... 与引用 [^a] ---------- */

// 定义行标记：行首（允许 ≤3 空格缩进）[^label]:，含尾随一个空白
const DEF_RE = /^[ \t]{0,3}\[\^([^\]\s]+)\]:[ \t]?/;
const REF_RE = /\[\^([^\]\s]+)\]/g;

/**
 * @returns { refs: [{from, to, label, n}], defs: [{from, to, markerFrom, markerTo, label}] }
 * 引用编号 n 按文档中首次引用的顺序分配。
 */
export function scanFootnotes(text, excludeRanges = []) {
  const defs = [];
  const defMarkers = []; // 定义标记范围（引用扫描需跳过，不计入编号）
  let lineStart = 0;
  while (lineStart <= text.length) {
    const nl = text.indexOf("\n", lineStart);
    const lineEnd = nl < 0 ? text.length : nl;
    const m = DEF_RE.exec(text.slice(lineStart, lineEnd));
    if (m) {
      const markerFrom = lineStart + m[0].indexOf("[");
      const markerTo = lineStart + m[0].length;
      if (!intersects(excludeRanges, markerFrom, markerTo)) {
        defs.push({ from: lineStart, to: lineEnd, markerFrom, markerTo, label: m[1] });
        defMarkers.push({ from: markerFrom, to: markerTo });
      }
    }
    if (nl < 0) break;
    lineStart = nl + 1;
  }

  const refs = [];
  const excl = [...excludeRanges, ...defMarkers];
  REF_RE.lastIndex = 0;
  let rm;
  while ((rm = REF_RE.exec(text))) {
    const from = rm.index;
    const to = from + rm[0].length;
    if (text[from - 1] === "!") continue; // 图片 alt 不算引用
    if (escaped(text, from)) continue;
    if (intersects(excl, from, to)) continue;
    refs.push({ from, to, label: rm[1] });
  }
  // 编号：按首次引用顺序
  const order = new Map();
  for (const r of refs) {
    if (!order.has(r.label)) order.set(r.label, order.size + 1);
    r.n = order.get(r.label);
  }
  return { refs, defs };
}

/* ---------- 一次性扫描 ---------- */

/**
 * 扫描全部扩展语法。公式优先：高亮/脚注扫描时把公式范围一并排除
 * （公式内的 == 与 [^a] 不算数，避免 replace 装饰互相重叠）。
 */
export function scanExtended(text, excludeRanges = []) {
  const maths = scanMath(text, excludeRanges);
  const excl = [...excludeRanges, ...maths];
  const highlights = scanHighlights(text, excl);
  const { refs, defs } = scanFootnotes(text, excl);
  return { maths, highlights, footnoteRefs: refs, footnoteDefs: defs };
}
