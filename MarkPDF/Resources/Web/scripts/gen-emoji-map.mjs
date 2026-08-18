// 再生成 emoji 码表：npm i --no-save gemoji && node scripts/gen-emoji-map.mjs
// 产物 src/emoji-map.js 为提交文件，正常构建不依赖 gemoji（不加进 dependencies）
import { gemoji } from "gemoji";
import { writeFileSync } from "node:fs";

const entries = [];
for (const item of gemoji) {
  for (const name of item.names) entries.push([name, item.emoji]);
}
entries.sort((a, b) => (a[0] < b[0] ? -1 : 1));
const body = entries.map(([n, e]) => "[" + JSON.stringify(n) + "," + JSON.stringify(e) + "]").join(",");
const out = `// 由 gemoji（GitHub 官方 emoji 码表，${gemoji.length} 条/含别名）生成：shortcode → emoji 字符。
// 再生成：npm i --no-save gemoji && node scripts/gen-emoji-map.mjs（本文件为提交产物，构建不依赖 gemoji）。
export const EMOJI_MAP = new Map([${body}]);
`;
writeFileSync(new URL("../src/emoji-map.js", import.meta.url), out);
console.log(`emoji-map: ${entries.length} names, ${out.length} bytes`);
