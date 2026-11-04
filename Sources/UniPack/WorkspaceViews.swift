import SwiftUI
import UniPackCore

struct HistoryScreen: View {
  @EnvironmentObject var m: AppModel
  @State private var filter = "全部"
  var filtered: [BuildJob] {
    m.jobs.filter {
      filter == "全部" || (filter == "进行中" ? $0.status.isActive : $0.status == .failed)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("构建任务").font(.system(size: 27, weight: .semibold))
        Spacer()
        Text("\(m.activeCount) 个进行中").foregroundStyle(UP.muted)
      }
      Choices(selection: $filter, values: ["全部", "进行中", "失败"], title: { $0 })
      Rule()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if filtered.isEmpty {
            Text("没有" + (filter == "全部" ? "" : filter) + "的构建任务。").foregroundStyle(UP.muted)
              .padding(.vertical, 20)
          }
          ForEach(filtered) { JobRow(job: $0, showProject: true) }
          if filter == "全部", !m.records.isEmpty {
            Subhead(title: "早期 iOS 记录").padding(.top, 20)
            ForEach(m.records) { LegacyRow(record: $0) }
          }
        }
      }
    }.padding(.horizontal, 30).padding(.top, 36)
  }
}
struct EnvironmentScreen: View {
  @EnvironmentObject var m: AppModel
  @State private var picking = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("环境与 SDK").font(.system(size: 27, weight: .semibold))
        Subhead(title: "构建环境", note: "所有项目共用")
        FieldLine(title: "并发任务") {
          Choices(
            selection: m.envBinding(\.concurrency), values: [1, 2, 3, 4], title: { String($0) })
          Spacer()
        }
        PathRow(title: "HBuilderX", value: m.envBinding(\.hbuilderPath), directory: true)
        PathRow(title: "Xcode 开发目录", value: m.envBinding(\.xcodePath), directory: true)
        PathRow(title: "CocoaPods", value: m.envBinding(\.podPath))
        PathRow(title: "Android SDK", value: m.envBinding(\.androidSDKPath), directory: true)
        PathRow(title: "JDK Home", value: m.envBinding(\.javaHome), directory: true)
        TextLine(
          title: "依赖代理", value: m.envBinding(\.dependencyProxy), hint: "可选 · HTTP 或 HTTPS 地址")
        Rule()
        Subhead(title: "Vapor SDK", note: "HBuilderX " + m.environment.hbuilderVersion)
        FieldLine(title: "目标项目") {
          VStack(alignment: .leading, spacing: 5) {
            Button {
              picking.toggle()
            } label: {
              HStack {
                Text(m.sdkProject.flatMap { m.project($0)?.label } ?? "选择项目")
                Spacer()
                Image(systemName: "chevron.down")
              }.contentShape(Rectangle())
            }.buttonStyle(ToolStyle()).disabled(m.projects.isEmpty)
            if picking {
              ForEach(m.projects) { p in
                Button {
                  m.sdkProject = p.id
                  picking = false
                } label: {
                  HStack {
                    Text(p.label)
                    Spacer()
                    if p.id == m.sdkProject { Image(systemName: "checkmark") }
                  }.padding(7)
                }.buttonStyle(HoverRow())
              }
            }
          }
        }
        FieldLine(title: "平台") {
          Choices(selection: $m.sdkPlatform, values: BuildPlatform.allCases, title: { $0.title })
          Spacer()
        }
        .onChange(of: m.sdkPlatform) {
          m.sdkReleases = []
          m.sdkMessage = ""
        }
        if let id = m.sdkProject, let p = m.project(id) {
          Text((m.sdkPlatform == .ios ? p.sdkPath : p.android.sdkPath).nonEmpty ?? "尚未配置 SDK")
            .foregroundStyle(UP.muted).font(.caption).textSelection(.enabled)
        }
        HStack {
          Action("获取官方版本", "arrow.clockwise") { m.fetchSDK() }
          Action("导入 SDK", "folder") { m.importSDK() }
          Spacer()
          if m.sdkProgress != nil { Action("取消下载", "xmark") { m.cancelSDK() } }
        }.disabled(m.sdkProject == nil)
        if let progress = m.sdkProgress {
          Meter(fraction: progress)
          Text("\(Int(progress*100))%").monospacedDigit()
        }
        if !m.sdkMessage.isEmpty {
          Text(m.sdkMessage).foregroundStyle(UP.secondary).textSelection(.enabled)
        }
        ForEach(m.sdkReleases) { r in
          HStack {
            Text(m.sdkPlatform.title + " · Vapor " + r.version)
            Spacer()
            Action("下载并安装", "arrow.down.circle") { m.downloadSDK(r) }.disabled(
              m.sdkProject == nil || m.sdkProgress != nil
                || r.version
                  != m.environment.hbuilderVersion.split(separator: ".").prefix(2).joined(
                    separator: ".")
            )
          }
        }
      }.padding(.horizontal, 30).padding(.top, 36).padding(.bottom, 24)
    }
  }
}
