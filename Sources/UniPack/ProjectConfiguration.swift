import AppKit
import SwiftUI
import UniPackCore

struct ProjectConfiguration: View {
  let project: ProjectConfig
  @EnvironmentObject var catalog: ProjectCatalog
  private var summary: ProjectSummary? { catalog.entries[project.id] }
  private let columns = [GridItem(.adaptive(minimum: 380), spacing: 28, alignment: .topLeading)]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("manifest.json").font(.system(size: 15, weight: .semibold))
        Text("自动读取").font(.system(size: 11)).foregroundStyle(UP.muted)
        Spacer()
        Action("打开 manifest", "doc.text", tone: .quiet) {
          NSWorkspace.shared.open(
            URL(fileURLWithPath: project.path).appendingPathComponent("manifest.json"))
        }
      }
      Text("基本信息来自工程。下方按平台管理已启用服务，填写后自动保存，打包时导入。")
        .font(.system(size: 12)).foregroundStyle(UP.secondary)
      if let summary {
        if let issue = summary.issue {
          Text(issue).foregroundStyle(UP.warning).textSelection(.enabled)
        } else {
          ForEach(summary.configuration.filter { $0.id == "app" }) { group in
            VStack(alignment: .leading, spacing: 14) {
              Subhead(title: group.title)
              LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(group.items.filter { $0.id != "privacy" }) { item in
                  parameter(item.title, value: item.value)
                }
              }
              if group.id == "app", !summary.detail.isEmpty {
                Text(summary.detail).font(.system(size: 12)).foregroundStyle(UP.secondary)
                  .textSelection(.enabled)
              }
            }
            Rule()
          }
          PlatformServiceForm(id: project.id, platform: .ios).id(project.id.uuidString + ".ios")
          PlatformServiceForm(id: project.id, platform: .android).id(project.id.uuidString + ".android")
        }
      } else {
        Text("正在读取项目配置…").foregroundStyle(UP.muted)
      }
    }
  }
  private func parameter(_ title: String, value: String, fromBuildConfiguration: Bool = false)
    -> some View
  {
    HStack(alignment: .top, spacing: 12) {
      Text(title).foregroundStyle(UP.secondary).frame(width: 120, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Text(value.isEmpty ? (fromBuildConfiguration ? "请在构建配置中填写" : "未配置") : value)
          .foregroundStyle(value.isEmpty ? UP.muted : UP.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if fromBuildConfiguration {
          Text("来自构建配置").font(.system(size: 11)).foregroundStyle(UP.muted)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.font(.system(size: 12))
  }

}
