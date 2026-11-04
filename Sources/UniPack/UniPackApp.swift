import AppKit
import SwiftUI
import UniPackCore

@main struct UniPackApp: App {
  @StateObject private var model = AppModel()
  @StateObject private var catalog = ProjectCatalog()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup {
      Studio().environmentObject(model).environmentObject(catalog).preferredColorScheme(.dark)
        .onAppear { delegate.model = model }.onChange(
          of: model.projects.map(ProjectLocation.init), initial: true
        ) { _, roots in catalog.observe(roots) }
    }
    .windowStyle(.hiddenTitleBar).defaultSize(width: 1160, height: 790)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("添加项目…") { model.addProjects() }.keyboardShortcut("o")
        Button("返回项目列表") {
          model.section = "项目"
          model.path = []
        }.keyboardShortcut("1")
      }
    }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    model.persist()
    guard model.activeCount > 0 else { return .terminateNow }
    sender.windows.first?.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    model.confirmQuit = true
    return .terminateLater
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool)
    -> Bool
  {
    if !visible { sender.windows.first?.makeKeyAndOrderFront(nil) }
    return true
  }
}
struct Studio: View {
  @EnvironmentObject var m: AppModel
  @Environment(\.accessibilityReduceTransparency) var opaque
  private var modal: Bool { m.confirmQuit || m.removing != nil || m.error != nil }
  var body: some View {
    ZStack {
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            Text("UniPack").font(.system(size: 20, weight: .semibold))
          }
          .padding(.leading, 6).padding(.top, 44).padding(.bottom, 22)
          nav("项目", "square.stack.3d.up", m.projects.count)
          nav("构建任务", "clock.arrow.circlepath", m.activeCount)
          Spacer()
          Rule().padding(.bottom, 4)
          nav("环境与 SDK", "slider.horizontal.3", 0)
          HStack(spacing: 7) {
            Circle().fill(UP.success).frame(width: 6, height: 6)
            Text("本机工作空间").font(.system(size: 11)).foregroundStyle(UP.muted)
          }.padding(.horizontal, 12).padding(.vertical, 10)
        }.padding(.horizontal, 12).padding(.bottom, 10).frame(width: 192).background(
          opaque ? UP.sidebar : UP.sidebar.opacity(0.65))
        Rectangle().fill(UP.line).frame(width: 1)
        Group {
          if m.section == "环境与 SDK" {
            EnvironmentScreen()
          } else if m.section == "构建任务" {
            HistoryScreen()
          } else if let id = m.path.last, let p = m.project(id) {
            ProjectDetail(p: p).id(id)
          } else {
            LibraryScreen()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(
          UP.window)
      }.disabled(modal).accessibilityHidden(modal)
      if modal {
        Color.black.opacity(0.4)
        if m.confirmQuit {
          Dialog(
            title: "退出 UniPack？", message: "进行中的任务需要取消。HBuilderX 正在导出时，将等待本次导出结束。",
            confirm: "取消构建并退出", cancel: "继续构建",
            onCancel: {
              m.confirmQuit = false
              NSApp.reply(toApplicationShouldTerminate: false)
            }, action: { m.finishQuit() })
        } else if let id = m.removing, let p = m.project(id) {
          Dialog(
            title: "从列表移除「" + p.label + "」？", message: "移除这个项目的打包配置。本地工程文件、构建记录和已导出的安装包都会保留。",
            confirm: "移除项目", cancel: "保留", onCancel: { m.removing = nil },
            action: {
              m.removing = nil
              m.remove(id)
            })
        } else if let error = m.error {
          Dialog(
            title: "操作未完成", message: error, confirm: "知道了", cancel: nil,
            onCancel: { m.error = nil }, action: { m.error = nil })
        }
      }
    }.frame(minWidth: 910, minHeight: 610).foregroundStyle(UP.ink).font(.system(size: 13)).tint(
      UP.ink
    )
    .background { if !opaque { MaterialBacking() } else { UP.sidebar } }.ignoresSafeArea(
      .container, edges: .top)
  }
  private func nav(_ title: String, _ icon: String, _ count: Int) -> some View {
    Button {
      m.section = title
      if title == "项目" { m.path = [] }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 18)
        Text(title)
        Spacer()
        if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(UP.muted) }
      }
      .padding(.horizontal, 11).frame(height: 34).surface(
        m.section == title ? UP.raised : .clear, radius: 8,
        edge: m.section == title ? UP.line : .clear)
    }.buttonStyle(HoverRow()).accessibilityAddTraits(m.section == title ? .isSelected : [])
  }
}
struct HoverRow: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Hover(content: configuration.label, pressed: configuration.isPressed)
  }
  private struct Hover<V: View>: View {
    var content: V, pressed: Bool
    @State private var over = false
    var body: some View {
      content.contentShape(Rectangle()).background(
        over ? UP.field : .clear, in: RoundedRectangle(cornerRadius: 8)
      ).opacity(pressed ? 0.8 : 1).onHover { over = $0 }
    }
  }
}
struct Dialog: View {
  let title: String, message: String, confirm: String, cancel: String?, onCancel: () -> Void,
    action: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: 19, weight: .semibold))
      if message.count < 220 && message.components(separatedBy: .newlines).count < 8 {
        Text(message).foregroundStyle(UP.secondary).textSelection(.enabled).fixedSize(
          horizontal: false, vertical: true)
      } else {
        ScrollView {
          Text(message).foregroundStyle(UP.secondary).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }.frame(height: 160)
      }
      HStack {
        Spacer()
        if let cancel {
          Button(cancel, action: onCancel).buttonStyle(ToolStyle()).keyboardShortcut(.cancelAction)
        }
        Button(confirm, action: action).buttonStyle(ToolStyle(tone: .primary))
      }
    }.padding(24).frame(width: 410).surface(UP.raised, radius: 14).accessibilityAddTraits(.isModal)
  }
}
struct LibraryScreen: View {
  @EnvironmentObject var m: AppModel
  @EnvironmentObject var library: ProjectCatalog
  @FocusState private var searching: Bool
  var filtered: [ProjectConfig] {
    m.projects.filter { p in
      let s = library.entries[p.id]
      return m.search.isEmpty
        || [p.path, s?.name ?? "", s?.appID ?? ""].contains {
          $0.localizedCaseInsensitiveContains(m.search)
        }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("项目").font(.system(size: 27, weight: .semibold))
        Text("\(m.projects.count)").foregroundStyle(UP.muted).monospacedDigit()
        Spacer()
        Action("添加项目", "plus", tone: .primary) { m.addProjects() }.keyboardShortcut("n")
      }.padding(.bottom, 22)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(UP.muted)
        TextField("搜索项目名称、AppID 或路径", text: $m.search).textFieldStyle(.plain).focused($searching)
        if !m.search.isEmpty { Action("清除搜索", "xmark", tone: .icon) { m.search = "" } }
        Button("⌘F") { searching = true }.buttonStyle(.plain).foregroundStyle(UP.muted)
          .keyboardShortcut("f").accessibilityLabel("聚焦搜索")
      }.padding(.horizontal, 12).frame(height: 35).surface(
        UP.field, radius: 8, edge: searching ? UP.muted : UP.line)
      HStack(spacing: 16) {
        Text("应用").frame(maxWidth: .infinity, alignment: .leading)
        Text("iOS").frame(width: 122, alignment: .leading)
        Text("Android").frame(width: 122, alignment: .leading)
        Text("操作").frame(width: 65)
      }.font(.system(size: 11)).foregroundStyle(UP.muted).padding(.horizontal, 12).padding(.top, 24)
        .padding(.bottom, 9)
      Rule()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(filtered) { p in
            row(p)
            Rule()
          }
          if filtered.isEmpty {
            Text(m.search.isEmpty ? "添加一个 uni-app X Vapor 工程，开始本地打包。" : "没有找到匹配的项目。")
              .foregroundStyle(UP.muted).padding(40)
          }
        }
      }
    }.padding(.horizontal, 30).padding(.top, 36)
  }
  func row(_ p: ProjectConfig) -> some View {
    let s = library.entries[p.id]
    return HStack(spacing: 2) {
      Button {
        m.path = [p.id]
      } label: {
        HStack(spacing: 16) {
          HStack(spacing: 12) {
            ProjectMark(summary: s, fallback: p.label, size: 42)
            VStack(alignment: .leading, spacing: 6) {
              Text(s?.name.nonEmpty ?? p.label).font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
              Text(
                s?.issue != nil
                  ? "工程信息不可用"
                  : "\(p.label)  ·  \(s?.version.nonEmpty.map{"v"+$0} ?? "读取中")\(s.map{"  ·  "+$0.synced.formatted(date:.omitted,time:.standard)+" 同步"} ?? "")"
              )
              .lineLimit(1).foregroundStyle(s?.issue != nil ? UP.warning : UP.muted).font(
                .system(size: 12))
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          ForEach(BuildPlatform.allCases) { platform in
            let j = m.jobsFor(p.id, platform).first
            JobState(job: j).frame(width: 122, alignment: .leading).accessibilityLabel(
              platform.title + "，"
                + (j.map {
                  $0.status.isActive
                    ? $0.stage + "，" + String(Int($0.progress * 100)) + "%" : $0.status.title
                } ?? "未构建"))
          }
          Image(systemName: "chevron.right").foregroundStyle(UP.muted).frame(width: 30)
        }.padding(.leading, 12).frame(height: 78)
      }.buttonStyle(HoverRow()).help(p.path)
      Action("移除项目", "trash", tone: .icon) { m.requestRemove(p.id) }
    }.padding(.trailing, 12)
  }
}
