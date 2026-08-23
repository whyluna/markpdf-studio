import os
import PDFKit

/// PDF 标注状态中枢（模块 4）：标注工具/颜色状态、文档关联、防抖写回调度（FR-4.6）。
/// 主线程使用（开发规范 §3.2）；标注变更统一走 `markDirty()` → 500ms 防抖原子写回。
@MainActor
final class PDFAnnotationStore: ObservableObject {
  /// PDF annotation flags `/F` 的 ReadOnly 位（ISO 32000：bit position 7）。
  /// PDFAnnotation.isReadOnly 实测写的是 Widget 字段 `/Ff`，不能锁普通标注。
  nonisolated static let annotationReadOnlyFlag = 1 << 6
  /// 当前 PDF 文件（nil = 无打开文档）
  @Published private(set) var currentFileURL: URL?
  /// 当前选中的标注工具（nil = 仅阅读/选择文本）
  @Published var activeTool: AnnotationKind?
  /// 各标注类型最近用色（FR-4.4；初始为各类型默认色，变更后持久化到 UserDefaults）
  @Published var colorsByKind: [AnnotationKind: AnnotationColor]
  /// 色板当前作用的标注类型（FR-4.4：选中工具时跟随切换）
  @Published var paletteKind: AnnotationKind = .highlight
  /// 有未写回的标注改动
  @Published private(set) var hasUnsavedChanges = false
  /// 最近一次写回错误（视图据此弹 alert 后置回 nil；NFR-5：文件操作异常须用户可感知）
  @Published var lastError: String?
  /// 标注结构版本号：增删改即 +1，驱动列表面板实时同步（FR-4.5）
  @Published private(set) var revision = 0 {
    // 列表缓存唯一刷新点：attach 即时 / 变更防抖后各重扫一次
    didSet { rescanAnnotationItems() }
  }
  /// 标注列表条目缓存（FR-4.5）：仅随 revision 刷新。视图 body 读此缓存——
  /// 全文档重扫含逐标注文本提取，不能随任意 @Published（activeTool/colorsByKind…）
  /// 变化触发的 body 重估而重跑
  @Published private(set) var annotationItemsSnapshot: [AnnotationItem] = []
  #if DEBUG
  /// 全文档重扫（缓存重建）次数（测试钩子：验证重复读缓存、无关 @Published 变化不重扫；
  /// 仅 DEBUG 编入，Release 不携带）
  private(set) var annotationItemsRescanCount = 0
  #endif

  private var writer: AnnotationWriter
  private let defaults: UserDefaults
  private let debouncer = Debouncer(interval: 0.5)
  /// 交互进行中查询（批注编辑框 / 点选编辑条是否打开）：由 AnnotationToolbarController 注册。
  /// 期间的标注变更只标脏不落盘，交互结束统一写（见 markDirty）。
  /// 用注册表而非单闭包：分栏双 PDF 各有一个控制器，单闭包会被后建者覆盖——
  /// A 窗交互中 store 查到的是 B 窗状态（false），写回正好砸在 A 打字中途
  private var interactionChecks: [UUID: () -> Bool] = [:]

  /// 注册交互源；返回令牌供注销（控制器 deinit 时调用）
  func registerInteractionCheck(_ check: @escaping () -> Bool) -> UUID {
    let id = UUID()
    interactionChecks[id] = check
    return id
  }

  func unregisterInteractionCheck(_ id: UUID) {
    interactionChecks[id] = nil
  }

  private var anyInteracting: Bool {
    interactionChecks.values.contains { $0() }
  }
  /// 交互期间攒下的变更（结束时排一次重扫 + 写回）
  private var hasDeferredWrites = false
  /// revision 刷新防抖：批注输入每键都 markDirty，全文档重扫（含逐标注文本提取）
  /// 不能按键频跑；列表最终一致即可
  private let revisionDebouncer = Debouncer(interval: 0.3)
  private weak var document: PDFDocument?
  /// 写回持续失败只提示一次（防抖窗口内反复重试），写回恢复后复位
  private var hasReportedWriteFailure = false
  /// sidecar 读取/解码失败（Bug 修复 6）：内存标注不完整，禁止写回覆盖原文件；
  /// 每次 attach 按加载结果重估（修复文件后重开即恢复写回）
  private var sidecarLoadFailed = false
  /// sidecar 加载持续失败只提示一次（attach 随分栏焦点切换反复发生），加载恢复后复位
  private var hasReportedSidecarLoadFailure = false

  init(writer: AnnotationWriter = LiveAnnotationWriter(), defaults: UserDefaults = .standard) {
    self.writer = writer
    self.defaults = defaults
    var colors: [AnnotationKind: AnnotationColor] = [:]
    for kind in AnnotationKind.allCases {
      if let raw = defaults.string(forKey: Self.colorKey(for: kind)),
        let saved = AnnotationColor(rawValue: raw)
      {
        colors[kind] = saved
      } else {
        colors[kind] = AnnotationColor.default(for: kind)
      }
    }
    colorsByKind = colors
  }

  private static func colorKey(for kind: AnnotationKind) -> String {
    "annotationColor.\(kind.rawValue)"
  }

  /// 关联当前文档（打开/切换 PDF、分栏焦点切换时调用）。
  /// 替换目标前先落盘旧 (document, url) 的挂起改动：分栏双 PDF 时防止 A 窗标注
  /// 随指向切换写进 B 文档（调用方须保证旧 document 仍有强引用，pdfView.document 在就成立）。
  /// 重复 attach 同一文档是 no-op——焦点认领每次点击都会调用，重跑会无谓 flush、
  /// 全页扫描屏蔽 Popup 并触发标注列表刷新
  func attach(document: PDFDocument, url: URL) {
    // 写回目的地一律以文档自带的 URL 为准。视图侧传来的 url 在切标签时会先于异步加载
    // 完成的 document 更新，那个空窗里的焦点认领会把「旧文档 + 新路径」配成一对，
    // 随后写回就把 A 文档整份序列化进 B 文件——实测答案那份覆盖了讲义，112 页原稿全丢。
    // 文档自带 URL 是唯一不会错配的事实来源（内存文档没有，退回调用方给的 url）
    let target = document.documentURL ?? url
    if !Self.isSameFile(target, url) {
      Logger.pdf.error(
        "attach 收到文档与路径错配，按文档自带 URL 纠正: 视图=\(url.path, privacy: .public) 文档=\(target.path, privacy: .public)"
      )
    }
    guard self.document !== document || currentFileURL != target else { return }
    flushPendingWrites()
    self.document = document
    currentFileURL = target
    // FR-4.7：按文件恢复只读模式与对应写回通道
    let sidecar = Self.persistedSidecarPaths(defaults: defaults).contains(target.path)
    isSidecarMode = sidecar
    writer = sidecar ? SidecarAnnotationWriter(pdfURL: target) : LiveAnnotationWriter()
    if sidecar {
      // 只读模式：从 sidecar JSON 重建标注到页面（失败经 lastError 上报，Bug 修复 6）
      restoreSidecarAnnotations(into: document, url: target)
    }
    hasUnsavedChanges = false
    revision += 1
    // 屏蔽 PDFKit 的原生标注交互（我们全权管理：点选 → 自绘虚线框 + 编辑条）：
    // ① Popup 伴侣窗从页面摘除——仅 shouldDisplay=false 仍参与命中测试，PDFView 会
    //    给它画带手柄的原生选中框（128×64pt，压住正文），还把那块区域的划词吃掉。
    //    既有批注的伴侣从磁盘加载回来是基类 PDFAnnotation，必须按 subtype 判（isPopup），
    //    另按父标注的 popup 属性再摘一遍（有些伴侣不在 /Annots 里）；
    // ② 批注由 CommentCardView + CommentConnectorLayer 自绘：隐藏原生 /Text 气泡与
    //    作为定位数据的下划线/高亮，避免卡片避让后原生图标从下面露出、正文重复画线；
    // ③ 标注一律设只读（含 PDF 自带的超链接/表单域/图形标注——它们同样会冒出手柄框
    //    并抢走该区域的文本选择，实测某页点任意处都出框）。
    // 运行时行为调整，不 markDirty
    var commentGroupIDs: Set<String> = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      commentGroupIDs.formUnion(
        page.annotations
          .filter(\.isCommentMarker)
          .compactMap(\.userName)
          .filter { isAnnotationGroupID($0) }
      )
    }
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        if annotation.isPopup {
          annotation.shouldDisplay = false
          page.removeAnnotation(annotation)
          continue
        }
        if let popup = annotation.popup {
          popup.shouldDisplay = false
          page.removeAnnotation(popup)
        }
        let kind = AnnotationKind.of(annotation)
        if annotation.isCommentMarker
          || (commentGroupIDs.contains(annotation.userName ?? "")
            && (kind == .highlight || kind == .underline))
        {
          Self.hideNativeCommentVisualForOverlay(annotation)
        }
        if Self.shouldLockNativeEditing(annotation) {
          Self.lockNativeInteraction(of: annotation)
        }
      }
    }
  }

  /// 是否应锁掉 PDFKit 原生编辑（纯函数可单测）：所有标注一律锁——
  /// 本 App 不做表单填写与原生标注编辑，全部交互走自绘通道。
  /// 含超链接（Link）：这类资料 PDF 给目录/选项行铺满不可见 Link，不锁的话
  /// PDFView 会选中它们并画带手柄的蓝框，还抢走该区域的文本选择（实测多页复现）。
  /// 只读只禁"修改标注"，不影响点击跳转（跳转走 PDFView 的 action 处理）
  nonisolated static func shouldLockNativeEditing(_ annotation: PDFAnnotation) -> Bool {
    annotation.type != nil
  }

  /// 对所有标注写标准 `/F` ReadOnly；Widget 额外保留 `/Ff` 只读语义。
  nonisolated static func lockNativeInteraction(of annotation: PDFAnnotation) {
    let flagsKey = PDFAnnotationKey(rawValue: "F")
    let current = (annotation.value(forAnnotationKey: flagsKey) as? NSNumber)?.intValue ?? 0
    annotation.setValue(current | annotationReadOnlyFlag, forAnnotationKey: flagsKey)
    let subtype = annotation.type.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    if subtype == "Widget" {
      annotation.isReadOnly = true
    }
  }

  /// 清除旧文件里的 NoView 标志（通用兼容迁移工具）。批注覆盖层不调用此方法：
  /// 它有独立的运行时显示策略，写回时也会分别处理 marker 与正文范围标记。
  @discardableResult
  nonisolated static func restorePortableVisibility(of annotation: PDFAnnotation) -> Bool {
    guard !annotation.shouldDisplay else { return false }
    annotation.shouldDisplay = true
    return true
  }

  /// MarkPDF 内由自绘卡片、虚线框和连接线完整呈现批注，原生 /Text 气泡及其正文定位
  /// 标记只会造成重复视觉。这里只改当前内存文档；写回时会在私有文档中重建为
  /// “标准 /Text 可见、正文定位标记隐藏”，兼顾 App 内体验与第三方阅读器兼容性。
  @discardableResult
  nonisolated static func hideNativeCommentVisualForOverlay(_ annotation: PDFAnnotation) -> Bool {
    guard annotation.shouldDisplay else { return false }
    annotation.shouldDisplay = false
    return true
  }

  /// 页面上是否已存在同款标注（类型 + 位置，0.5pt 容差）——恢复 sidecar 去重用。
  /// 不按颜色判：只读模式下改色只写 sidecar，PDF 本体里残留的是旧色，若按颜色判
  /// 会把改色后的条目当成「不存在」再叠一份
  nonisolated static func hasTwin(of annotation: PDFAnnotation, on page: PDFPage) -> Bool {
    page.annotations.contains { existing in
      existing.type == annotation.type
        && abs(existing.bounds.origin.x - annotation.bounds.origin.x) < 0.5
        && abs(existing.bounds.origin.y - annotation.bounds.origin.y) < 0.5
        && abs(existing.bounds.width - annotation.bounds.width) < 0.5
        && abs(existing.bounds.height - annotation.bounds.height) < 0.5
    }
  }

  // MARK: - 只读模式（FR-4.7）

  /// 当前文件是否只读标注模式（标注存同名 sidecar JSON，不改 PDF 本体）
  @Published private(set) var isSidecarMode = false

  private static let sidecarPathsKey = "sidecarModePaths"

  private static func persistedSidecarPaths(defaults: UserDefaults) -> Set<String> {
    Set(defaults.stringArray(forKey: sidecarPathsKey) ?? [])
  }

  /// 逐文件切换只读模式（持久化；切换只影响写回目的地，不迁移既有标注）
  func setSidecarMode(_ enabled: Bool) {
    guard let url = currentFileURL, enabled != isSidecarMode else { return }
    // 切换写回通道前先落盘挂起改动（Bug C1 同类）：否则防抖窗口内的变更
    // 会在下一次防抖触发时被写进新目的地
    flushPendingWrites()
    var paths = Self.persistedSidecarPaths(defaults: defaults)
    if enabled {
      paths.insert(url.path)
    } else {
      paths.remove(url.path)
    }
    defaults.set(Array(paths), forKey: Self.sidecarPathsKey)
    isSidecarMode = enabled
    writer = enabled ? SidecarAnnotationWriter(pdfURL: url) : LiveAnnotationWriter()
  }

  /// 从 sidecar JSON 重建标注到页面（只读模式）。
  /// 读取/解码失败经 lastError 上报（Bug 修复 6，NFR-5：不得静默吞成「无标注」），
  /// 并标记 sidecarLoadFailed 禁止后续写回——内存标注不完整，写回会用残缺数据覆盖原文件
  private func restoreSidecarAnnotations(into document: PDFDocument, url: URL) {
    sidecarLoadFailed = false
    let sidecarURL = SidecarAnnotationStorage.sidecarURL(for: url)
    // 文件不存在是常态（开启只读模式后尚未产生任何标注写回），不算失败；
    // 存在但读不出/解不开才是用户须感知的损坏
    guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
    do {
      let data = try Data(contentsOf: sidecarURL)
      for (pageIndex, annotation) in try SidecarAnnotationStorage.annotations(from: data) {
        guard let page = document.page(at: pageIndex) else { continue }
        // 去重：分栏焦点来回会重跑 attach（恢复再次执行）；开启只读模式前已写进
        // PDF 本体的标注也在页面上——不去重则副本层层叠加，下一次快照再把叠加
        // 写进 sidecar 永久化（实测高亮越叠越深、列表出现重复条目）
        guard !Self.hasTwin(of: annotation, on: page) else { continue }
        page.addAnnotation(annotation)
      }
      hasReportedSidecarLoadFailure = false
    } catch {
      sidecarLoadFailed = true
      Logger.pdf.error("sidecar 标注加载失败 \(sidecarURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      // 持续失败只提示一次（attach 随分栏焦点切换反复发生），避免弹窗轰炸
      if !hasReportedSidecarLoadFailure {
        hasReportedSidecarLoadFailure = true
        lastError = String(localized: "标注文件「\(sidecarURL.lastPathComponent)」读取失败：\(error.localizedDescription)。标注未加载；为保护原文件，本次不会向它写回。")
      }
    }
  }

  // MARK: - 标注变更

  /// 添加标注并调度写回
  func add(_ annotation: PDFAnnotation, to page: PDFPage) {
    // 只读：PDFKit 不再对它提供原生选中/拖动手柄——交互全走我们自己的通道
    //（点选 → 虚线框 + 编辑条；批注 → 自绘 popover）
    Self.lockNativeInteraction(of: annotation)
    page.addAnnotation(annotation)
    markDirty()
  }

  /// 移除标注并调度写回（便签型标注连带移除 Popup 伴侣）
  func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
    if let popup = annotation.popup, popup.page === page {
      page.removeAnnotation(popup)
    }
    page.removeAnnotation(annotation)
    markDirty()
  }

  /// 变更标注属性（颜色等）并调度写回
  func update(_ annotation: PDFAnnotation, mutate: (PDFAnnotation) -> Void) {
    mutate(annotation)
    markDirty()
  }

  /// 记录某类型最近用色并持久化（FR-4.4 记忆）
  func remember(color: AnnotationColor, for kind: AnnotationKind) {
    colorsByKind[kind] = color
    defaults.set(color.rawValue, forKey: Self.colorKey(for: kind))
  }

  // MARK: - 列表快照（FR-4.5）

  /// 全文档标注条目（实时全扫，开销大；视图请改读 annotationItemsSnapshot 缓存）。
  /// 导出等需要当下最新结果的调用方保留此入口——防抖窗口内的变更尚未刷新缓存
  func annotationItems() -> [AnnotationItem] {
    scanAnnotationItems()
  }

  /// 重扫全文档并刷新列表缓存（计数供测试断言缓存复用）
  private func rescanAnnotationItems() {
    #if DEBUG
    annotationItemsRescanCount += 1
    #endif
    annotationItemsSnapshot = scanAnnotationItems()
  }

  /// 全文档标注条目扫描（同组标注合并，含组内非管理类型成员如批注连接线；
  /// 无组的非管理类型如 Popup 不进列表）
  private func scanAnnotationItems() -> [AnnotationItem] {
    guard let document else { return [] }
    var grouped: [String: [PDFAnnotation]] = [:]
    var singles: [PDFAnnotation] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        if isAnnotationGroupID(annotation.userName) {
          grouped[annotation.userName!, default: []].append(annotation)
        } else if AnnotationKind.of(annotation) != nil {
          singles.append(annotation)
        }
      }
    }
    var items: [AnnotationItem] = []
    for (groupID, annotations) in grouped {
      if let item = makeItem(id: groupID, annotations: annotations) {
        items.append(item)
      }
    }
    for annotation in singles {
      if let item = makeItem(id: "\(ObjectIdentifier(annotation))", annotations: [annotation]) {
        items.append(item)
      }
    }
    return items
  }

  /// 组条目主标注：批注组以标记图标为主（contents = 批注正文，类型显示"批注"），
  /// 否则取首个受管理类型成员
  private func makeItem(id: String, annotations: [PDFAnnotation]) -> AnnotationItem? {
    let primary = annotations.first(where: \.isCommentMarker)
      ?? annotations.first(where: { AnnotationKind.of($0) != nil })
    guard let primary,
      let page = primary.page,
      let document
    else { return nil }
    let kind: AnnotationKind = primary.isCommentMarker
      ? .freeText
      : AnnotationKind.of(primary)!
    // 摘录：拼接各段覆盖文本，规整空白后截断
    let excerpt = annotations
      .compactMap { $0.page?.selection(for: $0.bounds)?.string }
      .joined(separator: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let name = (primary.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return AnnotationItem(
      id: id,
      annotations: annotations,
      kind: kind,
      color: primary.color,
      pageIndex: document.index(for: page),
      excerpt: String(excerpt.prefix(80)),
      name: name
    )
  }

  // MARK: - 写回调度（FR-4.6）

  /// 标注变更统一入口：标记脏并调度 500ms 防抖写回。
  /// hasUnsavedChanges 重复置 true 也会广播 @Published（每键触发全局重渲染），必须拦重
  func markDirty() {
    if !hasUnsavedChanges {
      hasUnsavedChanges = true
    }
    // 交互进行中（批注编辑框/点选编辑条打开）：只标脏，不排重扫与写回——
    // 全文档重扫（含逐标注文本提取）与写回前的序列化都得在主线程跑，落在打字/点色
    // 那一瞬会卡住 UI（实测新建批注要等约 1 秒才能输入、点色不跟手）。
    // 交互结束由 resumeDeferredWrites() 统一排一次；flushPendingWrites 仍照常兜底
    guard !anyInteracting else {
      hasDeferredWrites = true
      return
    }
    scheduleWrites()
  }

  /// 交互结束（编辑框关闭 / 编辑条收起）：把挂起的重扫与写回排上
  func resumeDeferredWrites() {
    guard hasDeferredWrites else { return }
    hasDeferredWrites = false
    scheduleWrites()
  }

  /// 进入交互前撤下已排的落盘（新建批注：创建时的 markDirty 早于编辑框出现，
  /// 那次 0.5s 写回正好砸在光标该出现的时刻——实测「要等一秒才能打字」）
  func deferPendingWrites() {
    guard hasUnsavedChanges else { return }
    debouncer.cancel()
    revisionDebouncer.cancel()
    hasDeferredWrites = true
  }

  private func scheduleWrites() {
    revisionDebouncer.schedule { [weak self] in
      self?.revision += 1
    }
    debouncer.schedule { [weak self] in
      self?.writeBackInBackground()
    }
  }

  /// 立即写回挂起的改动（切换文件 / 关窗 / 退出前）。
  /// 快照已定格为纯数据、目的地随任务携带，提交不依赖 document 存活——
  /// 因此默认不阻塞主线程（后台串行队列 FIFO 保证多次写入有序）；
  /// 仅退出进程等「过后再也没有机会写」的路径传 blocking: true，
  /// 否则 sync 等在途长任务（dataRepresentation 0.4~1.5s）会把后台耗时搬回主线程
  func flushPendingWrites(blocking: Bool = false) {
    debouncer.cancel()
    hasDeferredWrites = false
    guard let job = prepareWriteJob() else { return }
    if blocking {
      let result = Self.commitQueue.sync {
        Result { try job.writer.commit(job.entries, to: job.url) }
      }
      finish(result, url: job.url)
    } else {
      Self.commitQueue.async { [weak self] in
        let result = Result { try job.writer.commit(job.entries, to: job.url) }
        Task { @MainActor in
          self?.finish(result, url: job.url)
        }
      }
    }
  }

  /// 防抖到点的写回：主线程只把标注收成纯数据，重绘与落盘全在后台副本上做——
  /// PDFDocument.dataRepresentation() 会把每一页重新绘制一遍（采样实锤 0.4~1.5s），
  /// 留在主线程就是每次标注动作后的整秒卡顿
  private func writeBackInBackground() {
    guard let job = prepareWriteJob() else { return }
    Self.commitQueue.async { [weak self] in
      let result = Result { try job.writer.commit(job.entries, to: job.url) }
      Task { @MainActor in
        self?.finish(result, url: job.url)
      }
    }
  }

  /// 待落盘快照（Sendable：跨线程只带纯数据与目的地，不带 PDFKit 对象）
  private struct WriteJob: Sendable {
    let writer: AnnotationWriter
    let entries: [SidecarAnnotationStorage.Entry]
    let url: URL
  }

  /// 落盘串行队列：后台写与同步兜底写共用，FIFO 保证同一文件的多次写入不交错
  private static let commitQueue = DispatchQueue(
    label: "com.whyluna.markpdf.annotation-writeback",
    qos: .utility
  )

  /// 定格待落盘快照（读 PDFKit 对象，必须在主线程）；nil = 无需写回或提取已失败
  private func prepareWriteJob() -> WriteJob? {
    guard hasUnsavedChanges, let document, let url = currentFileURL else { return nil }
    // 最后一道闸：文档与目的地必须是同一文件。attach 已按文档自带 URL 纠正错配，
    // 万一被绕过也绝不能写——把 A 文档写进 B 文件是不可逆的数据损失（实测毁掉过原稿）
    if let documentURL = document.documentURL, !Self.isSameFile(documentURL, url) {
      Logger.pdf.error(
        "写回目的地与文档不一致，已拒写: 文档=\(documentURL.path, privacy: .public) 目的地=\(url.path, privacy: .public)"
      )
      return nil
    }
    // sidecar 加载失败后禁止写回（Bug 修复 6）：内存标注不完整，写回会用残缺数据
    // 覆盖原 sidecar；用户已在加载失败提示中被告知（修复/删除损坏文件后重开即恢复写回）
    if isSidecarMode, sidecarLoadFailed {
      Logger.pdf.error("sidecar 加载失败后跳过写回，避免覆盖原文件: \(url.path, privacy: .public)")
      return nil
    }
    do {
      let entries = try writer.snapshot(document: document)
      // 快照已定格，此后的改动归下一次写回
      hasUnsavedChanges = false
      return WriteJob(writer: writer, entries: entries, url: url)
    } catch {
      finish(.failure(error), url: url)
      return nil
    }
  }

  private func finish(_ result: Result<Void, Error>, url: URL) {
    switch result {
    case .success:
      hasReportedWriteFailure = false
      Logger.pdf.debug("标注已写回: \(url.lastPathComponent, privacy: .public)")
    case .failure(let error):
      // 脏标记置回：下次变更或兜底 flush 会重试
      hasUnsavedChanges = true
      Logger.pdf.error("标注写回失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      // 持续失败只提示一次（每次标注变更都会重试），避免弹窗轰炸
      guard !hasReportedWriteFailure else { return }
      hasReportedWriteFailure = true
      // FR-7.4 审查修复：权限不足（Finder 裸开工作区外 PDF，仅文件授权无法在
      // 同目录新建 .bak/.tmp/.json）时附补救引导——文案层解决，不加额外按钮
      if Self.isPermissionError(error) {
        lastError = String(localized: "标注写回失败「\(url.lastPathComponent)」：\(error.localizedDescription)。文件位于工作区外，设为工作区后即可正常标注。")
      } else {
        lastError = String(localized: "标注写回失败「\(url.lastPathComponent)」：\(error.localizedDescription)")
      }
    }
  }

  /// 是否同一文件（纯函数可单测）：符号链接与 /private 前缀等路径形态都归一后再比
  nonisolated static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath()
      == rhs.standardizedFileURL.resolvingSymlinksInPath()
  }

  /// 是否沙盒权限不足错误（纯函数可单测）：Cocoa 257/513 或 POSIX EPERM/EACCES。
  /// 裸开工作区外文件时，写回所需的同目录新建（.bak/.tmp/sidecar .json）必以此类错误失败；
  /// Cocoa 常把 POSIX 原因包进 underlying error，递归看一眼
  nonisolated static func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    switch nsError.domain {
    case NSCocoaErrorDomain
    where nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError,
      NSPOSIXErrorDomain where nsError.code == EPERM || nsError.code == EACCES:
      return true
    default:
      guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      return isPermissionError(underlying)
    }
  }
}
