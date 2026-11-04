import AppKit
import SwiftUI
import UniPackCore

struct ProjectDetail: View {
  let p: ProjectConfig
  @EnvironmentObject var m: AppModel
  @EnvironmentObject var library: ProjectCatalog
  private enum DetailTab: String, CaseIterable {
    case project = "项目配置"
    case configuration = "构建配置"
    case activity = "构建与产物"
  }
  @State private var tab = DetailTab.project
  private var available: Set<BuildPlatform> {
    p.selectedPlatforms.subtracting(active.map(\.platform))
  }
  private var actionTitle: String {
    if available.count == 2 { return "双端打包" }
    if available.count == 1, p.selectedPlatforms.count == 2 {
      return "打包 " + available.first!.title
    }
    return "开始打包"
  }
  var summary: ProjectSummary? { library.entries[p.id] }
  var mode: PackageMode { p.kind == .debug ? .debug : .release }
  var active: [BuildJob] { m.jobs.filter { $0.projectID == p.id && $0.status.isActive } }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Action("项目列表", "chevron.left", tone: .quiet) { m.path = [] }
        Spacer()
        Action("打开工程目录", "folder", tone: .quiet) {
          NSWorkspace.shared.open(URL(fileURLWithPath: p.path))
        }
      }.padding(.horizontal, 19).padding(.top, 25).padding(.bottom, 8)
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 16) {
          ProjectMark(summary: summary, fallback: p.label, size: 58)
          VStack(alignment: .leading, spacing: 6) {
            Text(summary?.name.nonEmpty ?? p.label).font(.system(size: 25, weight: .semibold))
            Text(
              [
                summary?.version.nonEmpty.map { "v" + $0 },
                summary?.build.nonEmpty.map { "构建号 " + $0 }, summary?.appID.nonEmpty,
              ].compactMap { $0 }.joined(separator: "   ·   ")
            )
            .foregroundStyle(UP.secondary).font(.system(size: 12)).textSelection(.enabled)
          }
          Spacer()
        }
        if let s = summary {
          Label(s.git.label, systemImage: "arrow.triangle.branch")
            .font(.system(size: 12)).foregroundStyle(UP.secondary)
            .lineLimit(1).truncationMode(.middle).help("Git：" + s.git.label)
            .accessibilityLabel("Git 状态：" + s.git.label)
          if let issue = s.issue {
            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(UP.warning)
              .textSelection(.enabled)
          } else {
            VStack(alignment: .leading, spacing: 6) {
              if !s.detail.isEmpty && s.detail != s.name {
                Text(s.detail).foregroundStyle(UP.secondary)
              }
              HStack {
                Text("Vapor" + (s.renderTarget.isEmpty ? "" : " · " + s.renderTarget))
                Text("·")
                Text("\(s.modules.count) 项模块声明").help(s.modules.joined(separator: "、"))
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(s.synced, format: .dateTime.hour().minute().second())
                Text("已同步")
              }.font(.system(size: 11)).foregroundStyle(UP.muted)
            }
          }
        }
        Choices(selection: $tab, values: DetailTab.allCases, title: { $0.rawValue })
      }.padding(.horizontal, 30).padding(.vertical, 10)
      Rule()
      ScrollView {
        Group {
          switch tab {
          case .project:
            ProjectConfiguration(project: p)
          case .configuration:
            VStack(alignment: .leading, spacing: 20) {
              BuildVersionEditor(id: p.id).id(p.id)
              Rule()
              SigningSection(p: p, platform: .ios)
              Rule()
              SigningSection(p: p, platform: .android)
              Rule()
              ProjectDependencies(project: p).id(p.id)
            }
          case .activity:
            ActivityList(project: p)
          }
        }.padding(.horizontal, 30).padding(.vertical, 16)
          .frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
      }.id(tab)
      Rule()
      VStack(spacing: 12) {
        ForEach(active) { j in
          HStack(spacing: 12) {
            Text(j.platform.title).frame(width: 55, alignment: .leading)
            JobState(job: j)
            Spacer()
            Action("取消任务", "xmark", tone: .quiet) { m.scheduler.cancel(j.id) }
          }
        }
        HStack(spacing: 10) {
          Text("包类型").foregroundStyle(UP.muted)
          Choices(
            selection: Binding(get: { mode }, set: { m.setMode($0, id: p.id) }),
            values: PackageMode.allCases, title: { $0 == .debug ? "自定义基座" : "正式包" })
          Text("平台（可多选）").foregroundStyle(UP.muted).padding(.leading, 6)
          HStack(spacing: 2) {
            ForEach(BuildPlatform.allCases) { platform in
              let selected = p.selectedPlatforms.contains(platform)
              Button {
                m.togglePlatform(platform, id: p.id)
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: selected ? "checkmark.square.fill" : "square")
                  Text(platform.title)
                }.font(.system(size: 12, weight: selected ? .semibold : .regular))
                  .foregroundStyle(selected ? UP.ink : UP.muted)
                  .padding(.horizontal, 8).frame(height: 27)
                  .surface(
                    selected ? UP.raised : .clear, radius: 6, edge: selected ? UP.line : .clear
                  )
                  .contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel(platform.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
          }.padding(3).surface(UP.sidebar.opacity(0.65), radius: 9)
          Spacer(minLength: 2)
          Action(actionTitle, "play.fill", tone: .primary) {
            if m.build(p.id, platforms: available, mode: mode) { tab = .activity }
          }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(summary?.issue != nil || summary == nil || available.isEmpty)
          .help(p.selectedPlatforms.isEmpty ? "请至少选择一个平台" : "每个所选平台创建独立任务，已运行的平台不会重复提交")
        }
      }.padding(.horizontal, 26).padding(.vertical, 14).background(UP.sidebar.opacity(0.7))
    }
  }
}

struct SigningSection: View {
  let p: ProjectConfig, platform: BuildPlatform
  @EnvironmentObject var m: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: platform == .ios ? "apple.logo" : "cpu").frame(width: 20).foregroundStyle(
          UP.secondary)
        Text(platform.title).font(.system(size: 17, weight: .semibold))
        Text(p.kind == .debug ? "自定义基座" : platform == .ios ? "App Store IPA" : "正式 APK").font(
          .system(size: 12)
        ).foregroundStyle(UP.muted)
        Spacer()
      }
      if platform == .ios {
        HStack(spacing: 18) {
          TextLine(
            title: "Bundle ID", value: m.binding(p.id, \.bundleID, default: ""),
            hint: "com.example.app")
          PathRow(title: "P12 文件", value: m.iosSigning(p.id, \.p12Path, default: ""))
        }
        HStack(spacing: 18) {
          PathRow(title: "描述文件", value: m.iosSigning(p.id, \.profilePath, default: ""))
          SavedPassword(title: "P12 密码", key: p.signing.passwordKey).id(p.signing.passwordKey)
        }
      } else {
        HStack(spacing: 18) {
          TextLine(
            title: "应用包名", value: m.androidBinding(p.id, \.applicationID, default: ""),
            hint: "com.example.app")
          PathRow(title: "Keystore", value: m.androidSigning(p.id, \.keystorePath, default: ""))
        }
        HStack(spacing: 18) {
          TextLine(
            title: "Alias", value: m.androidSigning(p.id, \.alias, default: ""), hint: "密钥别名")
          SavedPassword(title: "Keystore 密码", key: p.android.signing.storePasswordKey).id(
            p.android.signing.storePasswordKey)
        }
        HStack(spacing: 18) {
          SavedPassword(title: "私钥密码", key: p.android.signing.keyPasswordKey).id(
            p.android.signing.keyPasswordKey)
          Color.clear.frame(maxWidth: .infinity).frame(height: 1)
        }
        if p.android.signing.managed {
          Text("这是旧版自动生成的证书，请选择自己的 Keystore。").font(.caption).foregroundStyle(UP.warning)
        }
      }
      Fold(title: "高级设置") {
        if platform == .ios {
          PathRow(
            title: "Vapor SDK", value: m.binding(p.id, \.sdkPath, default: ""), directory: true)
          PathRow(
            title: "正式包目录", value: m.binding(p.id, \.outputPath, default: ""), directory: true,
            hint: "默认：unpackage/release/ios")
          PathRow(
            title: "Entitlements", value: m.binding(p.id, \.entitlementPath, default: ""),
            hint: "可选 · 附加能力文件")
        } else {
          PathRow(
            title: "Vapor SDK", value: m.androidBinding(p.id, \.sdkPath, default: ""),
            directory: true)
          PathRow(
            title: "正式包目录", value: m.androidBinding(p.id, \.outputPath, default: ""),
            directory: true, hint: "默认：unpackage/release/android")
          HStack {
            TextLine(title: "NDK 版本", value: m.androidBinding(p.id, \.ndkVersion, default: ""))
            TextLine(title: "CMake 版本", value: m.androidBinding(p.id, \.cmakeVersion, default: ""))
          }
        }
        let key = m.checkKey(p, platform)
        Action(m.checking.contains(key) ? "正在检查" : "检查环境与签名", "checkmark.circle") {
          m.preflight(p.id, platform: platform)
        }.disabled(m.checking.contains(key))
        ForEach(m.checks[key] ?? []) { item in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle" : "exclamationmark.triangle")
              .foregroundStyle(item.ok ? UP.success : UP.warning)
            Text(item.title).fontWeight(.medium)
            Text(item.detail).foregroundStyle(UP.secondary).textSelection(.enabled)
          }.font(.system(size: 12))
        }
      }
    }
  }
}

struct ActivityList: View {
  let project: ProjectConfig
  @EnvironmentObject var m: AppModel
  var body: some View {
    let jobs = m.jobs.filter { $0.projectID == project.id }
    LazyVStack(alignment: .leading, spacing: 8) {
      Subhead(title: "构建记录", note: "\(jobs.count) 次构建")
      if jobs.isEmpty { Text("构建完成后，可在这里查看日志和安装包。").foregroundStyle(UP.muted) }
      ForEach(jobs) { job in JobRow(job: job, showProject: false) }
      ForEach(m.records.filter { $0.project == project.path }) { LegacyRow(record: $0) }
    }
  }
}
struct JobRow: View {
  let job: BuildJob, showProject: Bool
  @State private var expanded = false
  @EnvironmentObject var m: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
            .frame(width: 12)
          VStack(alignment: .leading, spacing: 5) {
            Text(
              (showProject ? job.project.label + "  ·  " : "") + job.platform.title + "  ·  "
                + job.mode.title
            ).fontWeight(.medium)
            if let version = job.version {
              Text(version.title).font(.system(size: 11)).foregroundStyle(UP.secondary)
            }
            Text(job.created.formatted(date: .abbreviated, time: .shortened)).font(
              .system(size: 11)
            ).foregroundStyle(UP.muted)
          }
          Spacer()
          JobState(job: job).frame(maxWidth: 170, alignment: .trailing)
        }.contentShape(Rectangle()).padding(8)
      }.buttonStyle(HoverRow()).accessibilityValue(expanded ? "已展开" : "已折叠")
      ForEach(job.artifacts) { a in
        HStack(spacing: 8) {
          Image(systemName: "shippingbox")
          Text(URL(fileURLWithPath: a.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Spacer()
          Text(
            "v" + a.version + (a.versionCode.map { " · " + $0 } ?? "") + " · "
              + ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file)
          ).foregroundStyle(UP.muted)
          Action("定位产物", "folder", tone: .icon) { m.reveal(a.path) }
        }.padding(.leading, 28)
      }
      if expanded {
        if !job.detail.isEmpty {
          Text(job.detail).foregroundStyle(job.status == .failed ? UP.warning : UP.secondary)
            .textSelection(.enabled)
        }
        Fold(title: "本次打包依赖") { JobDependencies(job: job).id(job.id) }
        BuildLogPanel(job: job).id(job.id)
        HStack {
          if !job.logPath.isEmpty {
            Action("打开日志", "doc.text") {
              NSWorkspace.shared.open(URL(fileURLWithPath: job.logPath))
            }
          }
          if job.status.isActive {
            Action("取消任务", "xmark") { m.scheduler.cancel(job.id) }
          } else if m.project(job.projectID) != nil {
            Action("重新构建", "arrow.clockwise") {
              m.build(job.projectID, platforms: [job.platform], mode: job.mode)
            }
          }
          if showProject, m.project(job.projectID) != nil {
            Action("前往项目", "arrow.up.right") {
              m.section = "项目"
              m.path = [job.projectID]
            }
          }
        }
      }
      Rule()
    }.padding(.vertical, 3)
  }
}
struct LegacyRow: View {
  let record: BuildRecord
  @EnvironmentObject var m: AppModel
  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(record.kind.title + " · " + record.status)
        Text(record.date.formatted()).font(.caption).foregroundStyle(UP.muted)
      }
      Spacer()
      if !record.artifact.isEmpty { Action("定位产物", "folder") { m.reveal(record.artifact) } }
      if !record.logPath.isEmpty {
        Action("打开日志", "doc.text") { NSWorkspace.shared.open(URL(fileURLWithPath: record.logPath)) }
      }
    }.padding(.vertical, 8)
  }
}
