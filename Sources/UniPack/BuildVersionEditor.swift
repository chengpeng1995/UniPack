import SwiftUI
import UniPackCore

struct BuildVersionEditor: View {
  let id: UUID
  @EnvironmentObject var m: AppModel
  @EnvironmentObject var catalog: ProjectCatalog
  @State private var message = ""
  @State private var failure: String?
  private var active: Bool { m.jobs.contains { $0.projectID == id && $0.status.isActive } }
  private var draft: VersionDraft? { m.versionDrafts[id] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Subhead(title: "应用版本", note: "iOS 与 Android 共用")
      Text("保存会同步原工程 manifest.json；开始打包时也会先保存这里的修改。")
        .font(.system(size: 12)).foregroundStyle(UP.secondary)
      HStack(spacing: 18) {
        TextLine(title: "版本名称", value: m.versionBinding(id, \.name), hint: "例如 4.0.1")
        TextLine(title: "版本号", value: m.versionBinding(id, \.code), hint: "例如 2026110412")
      }.disabled(active || draft == nil).onSubmit { save() }
      HStack(spacing: 10) {
        Action("保存版本", "checkmark") { save() }.disabled(active || draft?.dirty != true)
        Action("重新读取", "arrow.clockwise", tone: .quiet) { reload(discard: true) }
          .help("丢弃未保存的版本输入，重新读取工程文件")
        if active {
          Text("构建中，版本暂不可修改").font(.system(size: 12)).foregroundStyle(UP.muted)
        } else if draft?.dirty == true {
          Text("有未保存的修改").font(.system(size: 12)).foregroundStyle(UP.muted)
        }
      }
      if let failure {
        Text(failure).font(.system(size: 12)).foregroundStyle(UP.warning)
      } else if !message.isEmpty {
        Text(message).font(.system(size: 12)).foregroundStyle(UP.muted)
      }
    }
    .task(id: catalog.entries[id]?.synced) { reload() }
  }
  private func reload(discard: Bool = false) {
    do {
      try m.loadVersion(id, discardEdits: discard)
      failure = nil
      if draft?.dirty != true { message = "已读取工程版本 · 保存后用于下一次构建" }
    } catch { failure = error.localizedDescription }
  }
  private func save() {
    do {
      try m.saveVersion(id)
      failure = nil
      message = "已同步到原工程 manifest.json"
    } catch { failure = error.localizedDescription }
  }
}
