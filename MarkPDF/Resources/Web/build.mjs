import { build } from "esbuild";

await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari16",
  outfile: "dist/editor.js",
  logLevel: "info",
  // KaTeX 字体：file loader 复制到 dist/ 并在 editor.css 中改写 url()
  loader: {
    ".woff": "file",
    ".woff2": "file",
    ".ttf": "file",
  },
});
