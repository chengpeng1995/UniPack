import AppKit
import SwiftUI
import UniPackCore

struct VersionDraft {
  let baseline: BuildVersion
  var name: String
  var code: String
  init(_ version: BuildVersion) {
    baseline = version
    name = version.name
    code = version.code
  }
  var dirty: Bool { name != baseline.name || code != baseline.code }
  var value: BuildVersion {
    BuildVersion(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      code: code.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

@MainActor final class AppModel: ObservableObject {
  @Published var projects: [ProjectConfig] = []
  @Published var versionDrafts: [UUID: VersionDraft] = [:]
  @Published var environment = EnvironmentConfig()
  @Published var records: [BuildRecord] = []
  @Published var jobs: [BuildJob] = []
  @Published var section = "项目"
  @Published var path: [UUID] = []
  @Published var search = ""
  @Published var removing: UUID?
  @Published var confirmQuit = false
  @Published var error: String?
  @Published var checks: [String: [CheckItem]] = [:]
  @Published var checking = Set<String>()
  @Published var sdkProject: UUID?
  @Published var sdkPlatform = BuildPlatform.ios
  @Published var sdkReleases: [SDKRelease] = []
  @Published var sdkProgress: Double?
  @Published var sdkMessage = ""
  @Published var credentialRevision = 0
  let store = ConfigStore(), scheduler: BuildScheduler
  private var sdkManager: SDKManager?, sdkRunner: ProcessRunner?, sdkTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  init() {
    var saved = ConfigStore.Saved()
    do { saved = try store.load() } catch {
      self.error = "配置读取失败，原文件已保留：\(error.localizedDescription)"
    }
    projects = saved.projects.map { p in
      var p = p
      let mode: PackageMode =
        p.selectedPlatforms == [.android] ? p.android.mode : (p.kind == .debug ? .debug : .release)
      p.kind = mode == .debug ? .debug : .appStore
      p.android.mode = mode
      return p
    }
    environment = saved.environment
    records = saved.records
    jobs = saved.jobs
    scheduler = BuildScheduler(jobs: saved.jobs)
    sdkProject = projects.first?.id
    scheduler.onChange = { [weak self] jobs in
      guard let self else { return }
      self.jobs = jobs
      self.save()
    }
    scheduler.limit = environment.concurrency
    save()
  }
  var activeCount: Int { jobs.filter { $0.status.isActive }.count }
  func project(_ id: UUID) -> ProjectConfig? { projects.first { $0.id == id } }
  func update(_ id: UUID, _ body: (inout ProjectConfig) -> Void) {
    guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
    body(&projects[i])
    checks = checks.filter { !$0.key.hasPrefix(id.uuidString) }
    save()
  }
  func binding<T>(_ id: UUID, _ key: WritableKeyPath<ProjectConfig, T>, default value: T)
    -> Binding<T>
  {
    Binding(
      get: { self.project(id)?[keyPath: key] ?? value },
      set: { v in self.update(id) { $0[keyPath: key] = v } })
  }
  func androidBinding<T>(_ id: UUID, _ key: WritableKeyPath<AndroidConfig, T>, default value: T)
    -> Binding<T>
  {
    Binding(
      get: { self.project(id)?.android[keyPath: key] ?? value },
      set: { v in self.update(id) { $0.android[keyPath: key] = v } })
  }
  func iosSigning<T>(_ id: UUID, _ key: WritableKeyPath<SigningConfig, T>, default value: T)
    -> Binding<T>
  {
    Binding(
      get: { self.project(id)?.signing[keyPath: key] ?? value },
      set: { v in self.update(id) { $0.signing[keyPath: key] = v } })
  }
  func androidSigning<T>(_ id: UUID, _ key: WritableKeyPath<AndroidSigning, T>, default value: T)
    -> Binding<T>
  {
    Binding(
      get: { self.project(id)?.android.signing[keyPath: key] ?? value },
      set: { v in
        self.update(id) {
          $0.android.signing[keyPath: key] = v
          if (key as AnyKeyPath) == \AndroidSigning.keystorePath {
            $0.android.signing.managed = false
          }
        }
      })
  }
  func envBinding<T>(_ key: WritableKeyPath<EnvironmentConfig, T>) -> Binding<T> {
    Binding(
      get: { self.environment[keyPath: key] },
      set: {
        self.environment[keyPath: key] = $0
        self.scheduler.limit = self.environment.concurrency
        self.save()
      })
  }
  func save() {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      persist()
    }
  }
  func persist() {
    do {
      try store.save(
        ConfigStore.Saved(
          projects: projects, environment: environment, records: records, jobs: jobs))
    } catch { self.error = "保存配置失败：" + error.localizedDescription }
  }
  func choose(
    _ title: String, directory: Bool = false, multiple: Bool = false, completion: ([URL]) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = directory
    panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = multiple
    if panel.runModal() == .OK { completion(panel.urls) }
  }
  func addProjects() {
    choose("选择 Vapor 项目或包含多个项目的目录", directory: true, multiple: true) { urls in
      var found: [URL] = []
      var failed: [String] = []
      for root in urls {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
        {
          found.append(root)
          continue
        }
        let skip = Set(["node_modules", "uni_modules", "unpackage", ".git", ".build"])
        if let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        {
          while let url = enumerator.nextObject() as? URL {
            if skip.contains(url.lastPathComponent)
              || url.pathComponents.count > root.pathComponents.count + 3
            {
              enumerator.skipDescendants()
              continue
            }
            if url.lastPathComponent == "manifest.json" {
              found.append(url.deletingLastPathComponent())
              enumerator.skipDescendants()
            }
          }
        }
      }
      for url in found {
        do {
          let info = try ProjectReader.inspect(url.path)
          let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
          if projects.contains(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == canonical
          }) {
            continue
          }
          var p = ProjectConfig(path: canonical)
          let ios =
            (info.manifest["app-ios"] as? [String: Any])?["distribute"] as? [String: Any] ?? [:]
          let android =
            (info.manifest["app-android"] as? [String: Any])?["distribute"] as? [String: Any] ?? [:]
          p.bundleID = ios["appid"] as? String ?? ios["bundleIdentifier"] as? String ?? ""
          p.android.applicationID = android["packagename"] as? String ?? ""
          let sdkRoot = Paths.data.appendingPathComponent("SDKs")
          if let sdk = try? SDKInfo.inspect(
            sdkRoot.appendingPathComponent("iOS-Vapor-" + environment.hbuilderVersion))
          {
            p.sdkPath = sdk.root.path
          }
          if let sdk = try? AndroidSDKInfo.inspect(
            sdkRoot.appendingPathComponent("Android-Vapor-" + environment.hbuilderVersion))
          {
            p.android.sdkPath = sdk.root.path
          }
          projects.append(p)
        } catch { failed.append(url.lastPathComponent + "：" + error.localizedDescription) }
      }
      if found.isEmpty { failed.append("没有找到 manifest.json。请选择 uni-app X Vapor 项目目录。") }
      if !failed.isEmpty { error = failed.joined(separator: "\n") }
      sdkProject = sdkProject ?? projects.first?.id
      section = "项目"
      save()
    }
  }
  func setMode(_ mode: PackageMode, id: UUID) {
    update(id) {
      $0.kind = mode == .debug ? .debug : .appStore
      $0.android.mode = mode
    }
  }
  func requestRemove(_ id: UUID) {
    guard !jobs.contains(where: { $0.projectID == id && $0.status.isActive }) else {
      error = "此项目仍有构建任务，请先完成或取消。"
      return
    }
    removing = id
  }
  func remove(_ id: UUID) {
    guard let p = project(id), !jobs.contains(where: { $0.projectID == id && $0.status.isActive })
    else {
      error = "项目正在构建，无法移除。"
      return
    }
    func refs(_ p: ProjectConfig) -> Set<String> {
      Set([
        p.debugSigning.passwordKey, p.releaseSigning.passwordKey,
        p.android.debugSigning.storePasswordKey, p.android.debugSigning.keyPasswordKey,
        p.android.releaseSigning.storePasswordKey, p.android.releaseSigning.keyPasswordKey,
        p.android.servicesKey, p.iosServicesKey,
      ])
    }
    let others = Set(projects.filter { $0.id != id }.flatMap { refs($0) })
    do { try LocalCredentialStore.clear(keys: refs(p).subtracting(others)) } catch {
      self.error = error.localizedDescription
      return
    }
    try? FileManager.default.removeItem(
      at: AndroidServices.generatedFile(id).deletingLastPathComponent())
    versionDrafts.removeValue(forKey: id)
    projects.removeAll { $0.id == id }
    path.removeAll { $0 == id }
    if sdkProject == id { sdkProject = projects.first?.id }
    checks = checks.filter { !$0.key.hasPrefix(id.uuidString) }
    persist()
  }
  func finishQuit() {
    confirmQuit = false
    for j in jobs where j.status.isActive { scheduler.cancel(j.id) }
    Task {
      while activeCount > 0 { try? await Task.sleep(for: .milliseconds(150)) }
      persist()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
  }
  func checkKey(_ p: ProjectConfig, _ platform: BuildPlatform) -> String {
    p.id.uuidString + platform.rawValue + p.kind.rawValue
  }
  func jobsFor(_ id: UUID, _ platform: BuildPlatform) -> [BuildJob] {
    jobs.filter { $0.projectID == id && $0.platform == platform }
  }
  func togglePlatform(_ platform: BuildPlatform, id: UUID) {
    update(id) { project in
      if !project.selectedPlatforms.insert(platform).inserted {
        project.selectedPlatforms.remove(platform)
      }
    }
  }

  func loadVersion(_ id: UUID, discardEdits: Bool = false) throws {
    guard let p = project(id) else { return }
    let version = try BuildVersion.read(project: p.path)
    if discardEdits || versionDrafts[id]?.dirty != true {
      versionDrafts[id] = VersionDraft(version)
    }
  }
  func versionBinding(_ id: UUID, _ key: WritableKeyPath<VersionDraft, String>) -> Binding<String> {
    Binding(
      get: { self.versionDrafts[id]?[keyPath: key] ?? "" },
      set: { value in
        guard var draft = self.versionDrafts[id] else { return }
        draft[keyPath: key] = value
        self.versionDrafts[id] = draft
      })
  }
  func saveVersion(_ id: UUID) throws {
    guard let p = project(id), let draft = versionDrafts[id], draft.dirty else { return }
    guard !jobs.contains(where: { $0.projectID == id && $0.status.isActive }) else {
      throw PackError("此项目正在构建，请等待任务结束后再保存版本")
    }
    let value = draft.value
    try ManifestVersionStore.save(value, project: p.path, expected: draft.baseline)
    versionDrafts[id] = VersionDraft(value)
    checks = checks.filter { !$0.key.hasPrefix(id.uuidString) }
  }

  @discardableResult
  func build(_ id: UUID, platforms: Set<BuildPlatform>, mode: PackageMode) -> Bool {
    guard let project = project(id) else { return false }
    do {
      guard !platforms.isEmpty else { throw PackError("请先选择打包平台") }
      try saveVersion(id)
      try scheduler.submit(
        project: project, environment: environment, platforms: platforms, mode: mode)
      persist()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func preflight(_ id: UUID, platform: BuildPlatform) {
    do { try saveVersion(id) } catch {
      self.error = error.localizedDescription
      return
    }
    guard let p = project(id) else { return }
    let env = environment
    let checkedVersion = try? BuildVersion.read(project: p.path)
    let key = checkKey(p, platform)
    guard !checking.contains(key) else { return }
    checking.insert(key)
    Task.detached {
      let backend: any PackagingBackend =
        platform == .ios ? IOSVaporBackend() : AndroidVaporBackend()
      let result = backend.preflight(project: p, environment: env)
      await MainActor.run {
        if self.project(id) == p, (try? BuildVersion.read(project: p.path)) == checkedVersion {
          self.checks[key] = result
        }
        self.checking.remove(key)
      }
    }
  }
  func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
  func savePlatformServices(_ values: [String: String], project: ProjectConfig, platform: BuildPlatform) throws {
    guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw PackError("项目已被移除") }
    let current = projects[index]
    let firstSave = !PlatformServices.managed(current, platform)
    let reference = platform == .ios ? current.iosServicesKey : current.android.servicesKey
    let previous = firstSave ? try LocalCredentialStore.password(key: reference) : nil
    try PlatformServices.save(values, project: current, platform: platform)
    var next = projects
    if platform == .ios { next[index].iosServicesManaged = true; next[index].iosServicesRevision += 1 }
    else { next[index].android.servicesManaged = true; next[index].android.servicesRevision += 1 }
    if firstSave {
      // 首次采用 GUI 配置时同时保存引用；避免退出后仍回退到工程中的旧值。
      do { try store.save(.init(projects: next, environment: environment, records: records, jobs: jobs)) }
      catch {
        if let previous { try LocalCredentialStore.savePassword(previous, key: reference) }
        else { try LocalCredentialStore.clear(key: reference) }
        throw error
      }
    }
    projects = next
    checks = checks.filter { !$0.key.hasPrefix(project.id.uuidString) }
    if !firstSave { save() }
  }
  func remember(_ value: String, key: String) {
    do {
      try LocalCredentialStore.savePassword(value, key: key)
      credentialRevision += 1
    } catch { self.error = error.localizedDescription }
  }
  func forget(_ key: String) {
    do {
      try LocalCredentialStore.clear(key: key)
      credentialRevision += 1
    } catch { self.error = error.localizedDescription }
  }
  func fetchSDK() {
    sdkMessage = "正在读取官方版本…"
    let platform = sdkPlatform
    Task {
      do {
        let list = try await SDKManager.releases(platform: platform)
        if sdkPlatform == platform {
          sdkReleases = list
          sdkMessage = "请选择匹配 HBuilderX 的 5.34 版本。"
        }
      } catch { sdkMessage = error.localizedDescription }
    }
  }
  func importSDK() {
    guard let id = sdkProject else {
      error = "请先选择项目"
      return
    }
    let platform = sdkPlatform
    choose("选择已解压的 Vapor SDK", directory: true) { urls in
      guard let url = urls.first else { return }
      do {
        let root: URL
        if platform == .ios {
          let sdk = try SDKInfo.inspect(url)
          try sdk.validate(hbuilder: environment.hbuilderVersion)
          root = sdk.root
        } else {
          let sdk = try AndroidSDKInfo.inspect(url)
          try sdk.validate(hbuilder: environment.hbuilderVersion)
          root = sdk.root
        }
        update(id) {
          if platform == .ios { $0.sdkPath = root.path } else { $0.android.sdkPath = root.path }
        }
        sdkMessage = "SDK 校验通过，已保存到此项目。"
      } catch { self.error = error.localizedDescription }
    }
  }
  func downloadSDK(_ release: SDKRelease) {
    guard let id = sdkProject, sdkProgress == nil else { return }
    let platform = sdkPlatform
    let version = environment.hbuilderVersion
    let manager = SDKManager()
    let runner = ProcessRunner()
    sdkManager = manager
    sdkRunner = runner
    sdkProgress = 0
    sdkTask = Task {
      let zip = Paths.data.appendingPathComponent("Downloads/" + UUID().uuidString + ".zip")
      defer {
        try? FileManager.default.removeItem(at: zip)
        sdkProgress = nil
        sdkManager = nil
        sdkRunner = nil
        sdkTask = nil
      }
      do {
        _ = try await manager.download(release, to: zip) { progress in
          Task { @MainActor in self.sdkProgress = progress }
        }
        try Task.checkCancellation()
        sdkMessage = "正在解压并校验 SDK…"
        let root = try await Task.detached {
          try SDKManager.install(
            zip: zip, release: release, platform: platform, hbuilder: version, runner: runner,
            log: { _ in })
        }.value
        update(id) {
          if platform == .ios { $0.sdkPath = root.path } else { $0.android.sdkPath = root.path }
        }
        sdkMessage = "已安装 \(platform.title) Vapor SDK \(release.version)"
      } catch { sdkMessage = Task.isCancelled ? "已取消 SDK 下载或安装" : error.localizedDescription }
    }
  }
  func cancelSDK() {
    sdkTask?.cancel()
    sdkManager?.cancel()
    sdkRunner?.cancel()
  }
}
