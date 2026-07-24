// 内核界面文案（FR：界面语言设置）：语言由 native 经页面 URL ?lang= 注入，
// 重启后生效（每个 WebView 加载时取一次）。缺省中文。
const STRINGS = {
  zh: {
    placeholder: "开始输入 Markdown…",
    copyCode: "复制代码",
    imageFallbackAlt: "图片",
    imageDraftUnsupported: "（草稿暂不支持相对路径图片）",
    imageLoadFailed: "图片加载失败：",
    exportFallbackTitle: "Markdown 导出",
  },
  en: {
    placeholder: "Start typing Markdown…",
    copyCode: "Copy code",
    imageFallbackAlt: "Image",
    imageDraftUnsupported: " (relative-path images are not supported in drafts)",
    imageLoadFailed: "Failed to load image: ",
    exportFallbackTitle: "Markdown Export",
  },
};

function currentLang() {
  try {
    const lang = new URLSearchParams(location.search).get("lang");
    return lang === "en" ? "en" : "zh";
  } catch {
    return "zh";
  }
}

const lang = currentLang();

export function t(key) {
  return STRINGS[lang][key] ?? STRINGS.zh[key] ?? key;
}

export { STRINGS };
