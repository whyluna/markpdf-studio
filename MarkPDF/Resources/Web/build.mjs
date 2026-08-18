import { build } from "esbuild";

const shared = {
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari16",
  logLevel: "info",
  // KaTeX 字体：file loader 复制到 dist/ 并在 editor.css 中改写 url()
  loader: {
    ".woff": "file",
    ".woff2": "file",
    ".ttf": "file",
  },
};

await build({
  ...shared,
  entryPoints: ["src/main.js"],
  outfile: "dist/editor.js",
});

// Mermaid 独立产物（P1-4 懒加载）：```mermaid 块首次出现时才注入加载，不拖慢启动
await build({
  ...shared,
  entryPoints: ["src/mermaid-entry.js"],
  outfile: "dist/mermaid-render.js",
});
