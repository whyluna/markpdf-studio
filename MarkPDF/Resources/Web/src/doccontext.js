// 文档上下文：内核与装饰层共享（避免 main.js ↔ wysiwyg.js 循环依赖）

export const docContext = {
  /** 当前文档的基准目录（file:// 形式，md 文件所在目录；草稿为 null） */
  baseURL: null,
};
