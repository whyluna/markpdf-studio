// 文档上下文：内核与装饰层共享（避免 main.js ↔ wysiwyg.js 循环依赖）

export const docContext = {
  /** 当前文档的基准目录（file:// 形式，md 文件所在目录；草稿为 null） */
  baseURL: null,
  /** mermaid 懒加载脚本的供给地址：App 内经 markpdf-file:// 协议（file:// 页面
   *  动态 <script> 加载本地资源被 WebKit 安全策略拦截）；浏览器调试回退相对路径 */
  mermaidScriptURL: null,
};
