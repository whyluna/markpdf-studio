// Mermaid 独立入口（P1-4 懒加载）：打成一个与 editor.js 分离的 IIFE 产物
// dist/mermaid-render.js——只有文档里出现 ```mermaid 块时才由 MermaidWidget
// 注入 <script> 加载（~2MB，不拖慢启动）。暴露 window.__markpdfMermaid。
import mermaid from "mermaid";

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict", // 不受信文档：转义 HTML 标签，防注入
  fontFamily: "inherit",
});

window.__markpdfMermaid = mermaid;
