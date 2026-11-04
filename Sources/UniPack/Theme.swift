import AppKit
import SwiftUI
import UniPackCore

enum UP {
  static func rgb(_ hex: UInt) -> Color {
    Color(
      red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
  static let ink = rgb(0xEDEDF0), secondary = rgb(0xBCBDC4), muted = rgb(0x95979F)
  static let window = rgb(0x1C1D20), sidebar = rgb(0x151619), raised = rgb(0x2C2D31)
  static let line = Color.white.opacity(0.08), field = Color.white.opacity(0.045),
    hover = Color.white.opacity(0.075)
  static let success = rgb(0x8CBCA5), warning = rgb(0xD7B57D), danger = rgb(0xE8968E)
  static func status(_ s: JobStatus) -> Color {
    switch s {
    case .succeeded: success
    case .failed: danger
    case .interrupted, .cancelled: warning
    default: secondary
    }
  }
}
struct MaterialBacking: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.blendingMode = .behindWindow
    v.material = .sidebar
    v.state = .active
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
extension View {
  func surface(_ fill: Color = UP.field, radius: CGFloat = 9, edge: Color = UP.line) -> some View {
    background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(edge)
          .allowsHitTesting(false)
      }
  }
}
struct Rule: View {
  var body: some View { Rectangle().fill(UP.line).frame(height: 1).accessibilityHidden(true) }
}
struct ToolStyle: ButtonStyle {
  enum Tone { case primary, normal, quiet, icon, delete }
  var tone: Tone = .normal
  func makeBody(configuration: Configuration) -> some View {
    StyledLabel(c: configuration, tone: tone)
  }
  private struct StyledLabel: View {
    let c: Configuration, tone: Tone
    @Environment(\.isEnabled) var enabled
    @Environment(\.accessibilityReduceMotion) var reduce
    @State var over = false
    var body: some View {
      c.label.font(.system(size: 13, weight: tone == .primary ? .semibold : .medium))
        .foregroundStyle(
          tone == .primary ? UP.window : tone == .delete ? UP.danger : over ? UP.ink : UP.secondary
        )
        .padding(.horizontal, tone == .icon ? 0 : 11).frame(
          width: tone == .icon ? 30 : nil, height: 32
        )
        .surface(
          tone == .primary
            ? (over ? .white : UP.ink) : over ? UP.hover : tone == .normal ? UP.field : .clear,
          radius: 8, edge: tone == .normal ? UP.line : .clear
        )
        .opacity(!enabled ? 0.4 : c.isPressed ? 0.75 : 1).contentShape(Rectangle())
        .onHover { over = $0 }.animation(reduce ? nil : .easeOut(duration: 0.13), value: over)
    }
  }
}
struct Action: View {
  let title: String, icon: String
  var tone: ToolStyle.Tone
  let perform: () -> Void
  init(
    _ title: String, _ icon: String, tone: ToolStyle.Tone = .normal, action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.tone = tone
    perform = action
  }
  var body: some View {
    Button(action: perform) {
      HStack(spacing: 6) {
        Image(systemName: icon)
        if tone != .icon { Text(title).fixedSize() }
      }
    }
    .buttonStyle(ToolStyle(tone: tone)).help(title).accessibilityLabel(title)
  }
}
struct Choices<T: Hashable>: View {
  @Binding var selection: T
  let values: [T], title: (T) -> String
  var body: some View {
    HStack(spacing: 2) {
      ForEach(values, id: \.self) { option in
        Button {
          selection = option
        } label: {
          Text(title(option)).fixedSize().font(
            .system(size: 12, weight: option == selection ? .semibold : .regular)
          )
          .foregroundStyle(option == selection ? UP.ink : UP.muted).padding(.horizontal, 12).frame(
            height: 27
          )
          .surface(
            option == selection ? UP.raised : .clear, radius: 6,
            edge: option == selection ? UP.line : .clear
          ).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(option == selection ? .isSelected : [])
      }
    }.padding(3).surface(UP.sidebar.opacity(0.65), radius: 9)
  }
}
struct InputBox: ViewModifier {
  @Environment(\.isFocused) var focused
  func body(content: Content) -> some View {
    content.textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10)
      .frame(height: 32).surface(UP.field, radius: 7, edge: focused ? UP.muted : UP.line)
  }
}
struct FieldLine<C: View>: View {
  let title: String
  @ViewBuilder var content: () -> C
  var body: some View {
    HStack(spacing: 12) {
      Text(title).foregroundStyle(UP.secondary).frame(width: 100, alignment: .leading)
      content()
    }
  }
}
struct TextLine: View {
  let title: String
  @Binding var value: String
  var hint = ""
  var body: some View {
    FieldLine(title: title) {
      TextField(hint, text: $value).accessibilityLabel(title).modifier(InputBox())
    }
  }
}
struct PathRow: View {
  let title: String
  @Binding var value: String
  var directory = false
  var hint = "选择文件"
  @EnvironmentObject var m: AppModel
  @FocusState private var editing: Bool
  var body: some View {
    FieldLine(title: title) {
      HStack(spacing: 6) {
        TextField(directory && hint == "选择文件" ? "选择目录" : hint, text: $value)
          .focused($editing).accessibilityLabel(title).foregroundStyle(
            editing || value.isEmpty ? UP.ink : .clear
          )
          .overlay(alignment: .leading) {
            if !editing && !value.isEmpty {
              Text(URL(fileURLWithPath: value).lastPathComponent).font(.system(size: 13)).lineLimit(
                1
              ).truncationMode(.middle)
                .foregroundStyle(UP.ink).allowsHitTesting(false).accessibilityHidden(true)
            }
          }.modifier(InputBox()).help(value)
        Action("选择" + title, "folder", tone: .icon) {
          m.choose(title, directory: directory) { if let url = $0.first { value = url.path } }
        }
      }
    }
  }
}
struct SavedPassword: View {
  let title: String, key: String
  @State private var value = ""
  @State private var saved = false
  @EnvironmentObject var m: AppModel
  var body: some View {
    FieldLine(title: title) {
      HStack(spacing: 6) {
        SecureField(saved ? "已记住 · 输入可更新" : "输入后自动记住", text: $value)
          .accessibilityLabel(title).modifier(InputBox()).onChange(of: value) { _, v in
            if !v.isEmpty { m.remember(v, key: key) }
          }
        if saved {
          Action("清除", "xmark", tone: .quiet) {
            value = ""
            m.forget(key)
          }
        } else {
          Button("无密码") { m.remember("", key: key) }.buttonStyle(ToolStyle(tone: .quiet))
        }
      }
    }.onChange(of: m.credentialRevision, initial: true) {
      saved = LocalCredentialStore.contains(key: key)
    }
  }
}
struct ProjectMark: View {
  let summary: ProjectSummary?, fallback: String, size: CGFloat
  var body: some View {
    Group {
      if let cg = summary?.logo {
        Image(decorative: cg, scale: 2).resizable().scaledToFit()
      } else {
        ZStack {
          UP.raised
          Text(String((summary?.name.nonEmpty ?? fallback).prefix(1))).font(
            .system(size: size * 0.43, weight: .medium)
          ).foregroundStyle(UP.secondary)
        }
      }
    }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
      .accessibilityHidden(true)
  }
}
extension String { var nonEmpty: String? { isEmpty ? nil : self } }
struct Meter: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(UP.line)
        Capsule().fill(UP.secondary).frame(width: geo.size.width * min(1, max(0, fraction)))
      }
    }.frame(height: 3).accessibilityHidden(true)
  }
}
struct JobState: View {
  let job: BuildJob?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Circle().fill(job.map { UP.status($0.status) } ?? UP.muted.opacity(0.4)).frame(
          width: 6, height: 6)
        Text(job.map { $0.status.isActive ? $0.stage : $0.status.title } ?? "未构建").lineLimit(1)
        if let job, job.status.isActive { Text("\(Int(job.progress*100))%").monospacedDigit() }
      }.font(.system(size: 12)).foregroundStyle(job.map { UP.status($0.status) } ?? UP.muted)
      if let job, job.status.isActive { Meter(fraction: job.progress) }
    }.help(job?.stage ?? "尚未构建")
  }
}
struct Subhead: View {
  let title: String
  var note = ""
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.system(size: 17, weight: .semibold))
      Spacer()
      if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(UP.muted) }
    }
  }
}
struct Fold<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content
  @State private var open = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        open.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12)
          Text(title)
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(ToolStyle(tone: .quiet)).accessibilityValue(open ? "已展开" : "已折叠")
      if open { content() }
    }
  }
}
