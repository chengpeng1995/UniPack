import AppKit
import SwiftUI
import UniPackCore

struct BuildLogPanel: View {
  let job: BuildJob
  @State private var preview: BuildLogTail?
  @State private var notice = "正在读取日志…"
  @State private var paused = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(preview?.clipped == true ? "日志预览 · 已节选，完整内容见日志文件" : "日志预览")
          .font(.system(size: 11)).foregroundStyle(UP.muted)
        Spacer()
        if job.status.isActive {
          Button(paused ? "继续刷新" : "暂停刷新") { paused.toggle() }
            .buttonStyle(ToolStyle(tone: .quiet))
        }
      }
      LogTextView(content: preview?.text.nonEmpty ?? notice)
        .frame(maxWidth: .infinity).frame(height: 194)
        .surface(UP.sidebar).accessibilityLabel("构建日志预览")
    }
    .task(id: Watch(id: job.id, path: job.logPath, active: job.status.isActive, paused: paused)) {
      // Expanded rows alone watch the file. A terminal state always performs one final read.
      guard !job.status.isActive || !paused else { return }
      let active = job.status.isActive
      let path = job.logPath
      repeat {
        if !path.isEmpty {
          let result = await Task.detached(priority: .utility) {
            Result { try BuildLogTail.read(URL(fileURLWithPath: path)) }
          }.value
          guard !Task.isCancelled else { return }
          switch result {
          case .success(let tail):
            if tail != preview { preview = tail }
            notice = active ? "等待日志输出…" : "日志文件为空。"
          case .failure(let error):
            preview = nil
            notice =
              (error as NSError).code == NSFileReadNoSuchFileError
              ? (active ? "等待日志文件…" : "未找到这次构建的日志文件。")
              : "日志读取失败：" + error.localizedDescription
          }
        } else {
          notice = active ? "任务排队中，开始后显示日志。" : "这次任务没有日志文件。"
        }
        guard active else { return }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
      } while !Task.isCancelled
    }
  }
  private struct Watch: Equatable { let id: UUID, path: String, active: Bool, paused: Bool }
}

// One width-constrained text container avoids the enormous intrinsic width of Xcode command lines.
// TextKit keeps selection, copying and scrolling functional within the preview.
private struct LogTextView: NSViewRepresentable {
  let content: String
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    guard let text = scroll.documentView as? NSTextView else { return scroll }
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = false
    text.textColor = NSColor(UP.secondary)
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.textContainerInset = NSSize(width: 10, height: 8)
    text.isHorizontallyResizable = false
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.lineBreakMode = .byCharWrapping
    text.setAccessibilityLabel("构建日志")
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView, text.string != content else { return }
    text.string = content
    text.scrollRangeToVisible(NSRange(location: (content as NSString).length, length: 0))
  }
}
