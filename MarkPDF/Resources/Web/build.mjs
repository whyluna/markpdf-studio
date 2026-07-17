import { build } from "esbuild";

await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari16",
  outfile: "dist/editor.js",
  logLevel: "info",
});
