import Foundation

/// 测试用具名 UserDefaults suite 的彻底清理。
/// `removePersistentDomain` 只清内存中的域，不保证删除磁盘上的 plist
///（容器 Preferences 目录曾因此堆积上千个测试残留文件），需连物理文件一并移除。
func removeTestDefaultsSuite(_ suiteName: String, using defaults: UserDefaults) {
  defaults.removePersistentDomain(forName: suiteName)
  let plist = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Preferences/\(suiteName).plist")
  try? FileManager.default.removeItem(at: plist)
}
