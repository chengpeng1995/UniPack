import AppKit
import CoreServices
import ImageIO
import SwiftUI
import UniPackCore

struct ProjectLocation: Equatable {
  let id: UUID
  let path: String
  init(_ project: ProjectConfig) {
    id = project.id
    path = project.path
  }
}
struct ProjectSummary {
  var name = "", appID = "", version = "", build = "", detail = "", renderTarget = ""
  var modules: [String] = []
  var configuration: [ManifestDisplayGroup] = []
  var git: ProjectGitInfo
  var logo: CGImage?
  var issue: String?
  var synced = Date()
  var tracked: [String] = []
  var stamps: [FileStamp?] = []
  static func read(_ path: String) -> Self {
    let git = ProjectGitInfo.read(path)
    var item = Self(git: git)
    item.tracked = [path, path + "/manifest.json"] + git.trackedPaths
    do {
      let info = try ProjectReader.inspect(path)
      item.name = info.name
      item.appID = info.appID
      item.version = info.version
      item.build = info.versionCode
      item.detail = info.manifest["description"] as? String ?? ""
      item.configuration = ManifestDisplayGroup.read(info.manifest)
      let vapor = info.manifest["uni-app-x"] as? [String: Any]
      item.renderTarget = vapor?["vapor-render-target"] as? String ?? ""
      let configs = ["app-ios", "app-android", "app"].compactMap {
        (info.manifest[$0] as? [String: Any])?["distribute"] as? [String: Any]
      }
      item.modules = Array(
        Set(configs.flatMap { Array(($0["modules"] as? [String: Any] ?? [:]).keys) })
      ).sorted()
      var candidates = configs.flatMap { iconPaths($0["icons"]) }
      candidates += [
        "static/logo.png", "static/images/common/logo.png", "unpackage/icons/1024x1024.png",
      ]
      let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      for var name in candidates where !name.isEmpty {
        if name.hasPrefix("@/") { name.removeFirst(2) }
        while name.hasPrefix("/") { name.removeFirst() }
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { continue }
        item.tracked.append(url.path)
        guard item.logo == nil, FileManager.default.isReadableFile(atPath: url.path),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { continue }
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 144,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
          item.logo = thumb
        }
      }
    } catch { item.issue = error.localizedDescription }
    item.stamps = item.tracked.map(FileStamp.read)
    return item
  }
  private static func iconPaths(_ value: Any?) -> [String] {
    if let s = value as? String { return s.isEmpty ? [] : [s] }
    guard let map = value as? [String: Any] else { return [] }
    let priority = [
      "appstore", "ios", "xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "android", "iphone", "ipad",
    ]
    return (priority + map.keys.filter { !priority.contains($0) }.sorted()).flatMap {
      iconPaths(map[$0])
    }
  }
}

// FSEvents can be unavailable, or silently omit a directory such as a system temp folder.
// Stat only the files that define the visible summary, without opening or decoding images.
struct FileStamp: Equatable {
  let inode: UInt64, size: Int64, seconds: Int, nanos: Int
  static func read(_ path: String) -> Self? {
    var status = stat()
    guard fstatat(AT_FDCWD, path, &status, 0) == 0 else { return nil }
    return Self(
      inode: status.st_ino, size: status.st_size, seconds: status.st_mtimespec.tv_sec,
      nanos: status.st_mtimespec.tv_nsec)
  }
}

// Subscribe to parents so atomic saves and deletion/recreation of a project root also arrive.
private final class ProjectEvents {
  private var stream: FSEventStreamRef?
  let receive: ([String], Bool) -> Void
  init(paths: [String], receive: @escaping ([String], Bool) -> Void) {
    self.receive = receive
    guard !paths.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let roots = Array(Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }))
    stream = FSEventStreamCreate(
      nil,
      { _, context, count, raw, flags, _ in
        guard let context else { return }
        let pointers = raw.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let dropped = (0..<count).contains {
          flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
        }
        Unmanaged<ProjectEvents>.fromOpaque(context).takeUnretainedValue().receive(
          (0..<count).map { String(cString: pointers[$0]) }, dropped)
      }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
      UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, .main)
      if !FSEventStreamStart(stream) {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
      }
    }
  }
  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
}

@MainActor final class ProjectCatalog: ObservableObject {
  @Published private(set) var entries: [UUID: ProjectSummary] = [:]
  private var locations: [ProjectLocation] = [], events: ProjectEvents?, pending = Set<UUID>()
  private var refreshTask: Task<Void, Never>?, fallback: Task<Void, Never>?
  func observe(_ next: [ProjectLocation]) {
    guard next != locations else { return }
    events = nil
    fallback?.cancel()
    locations = next
    let ids = Set(next.map(\.id))
    entries = entries.filter { ids.contains($0.key) }
    events = ProjectEvents(paths: next.map(\.path)) { [weak self] changes, lost in
      self?.changed(changes, lost: lost)
    }
    if !next.isEmpty {
      fallback = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(2))
          guard !Task.isCancelled, let self else { return }
          let known = entries.mapValues { ($0.tracked, $0.stamps) }
          let changes = await Task.detached(priority: .utility) {
            known.compactMap { id, old in old.0.map(FileStamp.read) != old.1 ? id : nil }
          }.value
          if !Task.isCancelled { schedule(Set(changes)) }
        }
      }
    }
    schedule(ids)
  }
  private func changed(_ paths: [String], lost: Bool) {
    let ids = locations.compactMap { location -> UUID? in
      let root = location.path
      return lost
        || paths.contains { path in
          if path == root || entries[location.id]?.git.trackedPaths.contains(path) == true {
            return true
          }
          guard path.hasPrefix(root + "/") else { return false }
          let relative = path.dropFirst(root.count + 1)
          if relative.hasPrefix("unpackage/icons/") || relative == "unpackage/icons" { return true }
          return ![".git", "node_modules", "unpackage", ".build", ".gradle"].contains(
            String(relative.split(separator: "/").first ?? ""))
        } ? location.id : nil
    }
    schedule(Set(ids))
  }
  private func schedule(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    pending.formUnion(ids)
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      while !pending.isEmpty {
        try? await Task.sleep(for: .milliseconds(150))
        let batch = locations.filter { self.pending.contains($0.id) }
        pending.removeAll()
        let result = await Task.detached(priority: .utility) {
          batch.map { ($0, ProjectSummary.read($0.path)) }
        }.value
        for (location, item) in result where locations.contains(location) {
          entries[location.id] = item
        }
      }
      refreshTask = nil
    }
  }
}
