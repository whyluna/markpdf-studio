# MarkPDF Studio App Icon v2 候选

> 状态：简洁版设计候选，尚未替换正式 `AppIcon.appiconset`。

## 设计原则

参考 Bear、iA Writer、Ulysses、PDF Expert、Craft、Obsidian 与主流 AI 应用在 macOS / App Store 上的图标后，只保留一个主轮廓：

- **Markdown**：文档上的大号 `#`。
- **PDF**：右上角小红色折角。
- **AI**：嵌在 `#` 中央交点的单个紫色四角星。
- **轻量**：单文档、无双页、无书本、无文字行、无复杂材质和装饰。

图标用一个符号同时表达三项能力，避免把功能拆成多个并列对象；大色块与粗线保证 16px / 32px 仍可辨认。

## 资产

- `app-icon-v2-master.png`：1024×1024 RGBA 母图，圆角外为真实透明像素。
- `AppIcon-v2.appiconset/`：16、32、64、128、256、512、1024 px 完整 Xcode 候选资产。

## 生成方式

底稿使用 Codex 内置 ImageGen 的 `logo-brand` 模式生成，外围透明使用确定性 Alpha 遮罩提取，尺寸由同一母图缩放。

最终提示词摘要：

> 为 MarkPDF Studio 设计一个极简 macOS 图标：钴蓝色圆角方形上只有一张居中的白色文档；文档右上角一个小红折角代表 PDF，文档中央一个粗体蓝色 `#` 代表 Markdown，`#` 的中央交点嵌入一个紫色四角星代表 AI。扁平、几何、高对比、16px 可读；仅一张文档、一个 `#`、一个折角、一个星，不使用双页、书本、文字行、金色标注、纸张纹理、玻璃效果或复杂阴影。
