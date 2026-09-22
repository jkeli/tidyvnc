// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

enum NativeSSHConfigurationSnapshotIssue: Error, Sendable, Equatable, CustomStringConvertible {
  case invalid, unsafeFile, changed, limit, unsupported
  var description: String { "SSH configuration could not be prepared safely. Review the supported settings and files." }
}

private final class SSHSnapshotFiles: @unchecked Sendable {
  let path: String
  private let lock = NSLock()
  private var fd: Int32
  private var identity: (dev_t,ino_t)?
  private var leaves: [(String,dev_t,ino_t)] = []
  init() throws {
    var template = Array("/tmp/tidyvnc-config-XXXXXX".utf8CString)
    guard let name = mkdtemp(&template) else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    path = String(cString:name); fd = -1
    // mkdtemp obeys the embedding process's umask. Establish owner access
    // without following a replacement symlink before opening the directory.
    var created = stat()
    guard lstat(path,&created) == 0, created.st_mode & S_IFMT == S_IFDIR, created.st_uid == geteuid(),
          fchmodat(AT_FDCWD,path,0o700,AT_SYMLINK_NOFOLLOW) == 0 else {
      rmdir(path); throw NativeSSHConfigurationSnapshotIssue.unsafeFile
    }
    fd = Darwin.open(path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { rmdir(path); throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    var info = stat()
    guard fstat(fd,&info) == 0, info.st_dev == created.st_dev, info.st_ino == created.st_ino else { Darwin.close(fd); fd = -1; rmdir(path); throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    identity = (info.st_dev,info.st_ino)
    guard let acl = acl_init(0) else { Darwin.close(fd); fd = -1; rmdir(path); throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED) == 0, fchmod(fd,0o700) == 0 else {
      Darwin.close(fd); fd = -1; rmdir(path); throw NativeSSHConfigurationSnapshotIssue.unsafeFile
    }
  }
  func write(_ bytes: Data, name: String) throws {
    try lock.withLock {
      guard fd >= 0 else { throw NativeSSHConfigurationSnapshotIssue.invalid }
      let output = openat(fd,name,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0o600)
      guard output >= 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
      defer { Darwin.close(output) }
      var info = stat()
      guard fstat(output,&info) == 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
      leaves.append((name,info.st_dev,info.st_ino))
      guard fchmod(output,0o600) == 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
      try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          try Task.checkCancellation()
          let count = Darwin.write(output,raw.baseAddress!.advanced(by:offset),raw.count-offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }; offset += count
        }
      }
    }
  }
  func remove() {
    lock.withLock {
      guard fd >= 0 else { return }
      for (name,device,inode) in leaves {
        var info = stat()
        if fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device, info.st_ino == inode,
           info.st_mode & S_IFMT == S_IFREG { unlinkat(fd,name,0) }
      }
      var directory = stat()
      let ownsPath = lstat(path,&directory) == 0 && directory.st_mode & S_IFMT == S_IFDIR &&
        directory.st_dev == identity?.0 && directory.st_ino == identity?.1
      Darwin.close(fd); fd = -1
      if ownsPath { rmdir(path) }
    }
  }
  deinit { remove() }
}

// Retain through every probe/connection using configurationURL; close only after
// consumers drain. No live source file is handed to OpenSSH. Cleanup is bounded
// and never recursively follows paths supplied by a configuration file.
final class NativeSSHConfigurationSnapshot: @unchecked Sendable {
  let configurationURL: URL
  private let files: SSHSnapshotFiles
  private init(files: SSHSnapshotFiles, name: String) {
    self.files = files; configurationURL = URL(fileURLWithPath:files.path).appendingPathComponent(name)
  }
  static func capture(root: URL, includeBase: URL, home: URL, allowMissingRoot: Bool = false,
                      checkpoint: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws -> NativeSSHConfigurationSnapshot {
    let work = Task.detached(priority:.utility) {
      try Task.checkCancellation()
      let files = try SSHSnapshotFiles()
      do {
        let builder = SSHSnapshotBuilder(files:files,includeBase:includeBase,home:home)
        let name = try builder.copyRoot(root,allowMissing:allowMissingRoot)
        try checkpoint(URL(fileURLWithPath:files.path)); try Task.checkCancellation(); try builder.validateSources()
        return NativeSSHConfigurationSnapshot(files:files,name:name)
      } catch { files.remove(); throw error }
    }
    return try await withTaskCancellationHandler {
      let snapshot = try await work.value
      do { try Task.checkCancellation(); return snapshot }
      catch { await snapshot.close(); throw error }
    } onCancel: { work.cancel() }
  }
  func close() async { let files = files; await Task.detached(priority:.utility) { files.remove() }.value }
  deinit { let files = files; DispatchQueue.global(qos:.utility).async { files.remove() } }
}

private final class SSHSnapshotBuilder {
  private struct Source {
    let info: stat, bytes: Data, name: String
  }
  private let files: SSHSnapshotFiles, includeBase: URL, home: URL
  private var sources: [String:Source] = [:], active: Set<String> = []
  private var revisions: [String:stat] = [:]
  private var absentRoot: URL?
  private var totalBytes = 0, references = 0, visitedEntries = 0
  init(files: SSHSnapshotFiles, includeBase: URL, home: URL) {
    self.files = files; self.includeBase = includeBase; self.home = home
  }
  private static let allowed: Set<String> = Set("""
    host hostname user port identityfile identityagent identitiesonly certificatefile
    pubkeyauthentication passwordauthentication kbdinteractiveauthentication kbdinteractivedevices
    preferredauthentications numberofpasswordprompts addkeystoagent usekeychain
    userknownhostsfile globalknownhostsfile hostkeyalias hashknownhosts hostkeyalgorithms
    casignaturealgorithms pubkeyacceptedalgorithms pubkeyacceptedkeytypes requiredrsasize revokedhostkeys
    verifyhostkeydns canonicalizehostname canonicaldomains canonicalizemaxdots canonicalizefallbacklocal
    canonicalizepermittedcnames addressfamily bindaddress bindinterface connecttimeout connectionattempts
    tcpkeepalive serveralivecountmax serveraliveinterval ipqos compression ciphers macs kexalgorithms
    rekeylimit gssapiauthentication gssapidelegatecredentials loglevel logverbose sendenv setenv tag
    controlmaster controlpath controlpersist forkafterauthentication requesttty sessiontype stdinnull
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
  private func validURL(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
          !url.path.utf8.contains(0) else { throw NativeSSHConfigurationSnapshotIssue.invalid }
  }
  private func same(_ a: stat,_ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_uid == b.st_uid &&
      a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  private func read(_ url: URL) throws -> (stat,Data) {
    try Task.checkCancellation(); try validURL(url)
    let fd = Darwin.open(url.path,O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }; defer { Darwin.close(fd) }
    var before = stat(), after = stat(), named = stat()
    guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_uid == geteuid() || before.st_uid == 0, before.st_mode & 0o022 == 0,
          before.st_size >= 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    guard before.st_size <= 65536 else { throw NativeSSHConfigurationSnapshotIssue.limit }
    if let acl = acl_get_fd_np(fd,ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      var entry: acl_entry_t?
      guard acl_get_entry(acl,Int32(ACL_FIRST_ENTRY.rawValue),&entry) == -1, errno == EINVAL else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    } else if errno != ENOENT { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    var bytes = Data(), chunk = [UInt8](repeating:0,count:4096)
    while true {
      try Task.checkCancellation()
      let count = Darwin.read(fd,&chunk,chunk.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
      if count == 0 { break }
      guard bytes.count + count <= 65536 else { throw NativeSSHConfigurationSnapshotIssue.limit }
      bytes.append(contentsOf:chunk.prefix(count))
    }
    guard fstat(fd,&after) == 0, lstat(url.path,&named) == 0, same(before,after), same(after,named), bytes.count == after.st_size else {
      throw NativeSSHConfigurationSnapshotIssue.changed
    }
    return (after,bytes)
  }
  private func validateMissingParents(_ root: URL) throws {
    var path = ""
    for component in root.path.split(separator:"/").dropLast() {
      try Task.checkCancellation(); path += "/" + component
      var info = stat()
      if lstat(path,&info) != 0 {
        if errno == ENOENT { return }
        throw NativeSSHConfigurationSnapshotIssue.unsafeFile
      }
      if info.st_mode & S_IFMT == S_IFLNK {
        guard stat(path,&info) == 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
      }
      guard info.st_mode & S_IFMT == S_IFDIR else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    }
  }
  func copyRoot(_ root: URL, allowMissing: Bool) throws -> String {
    try validURL(root); try validURL(includeBase); try validURL(home)
    if allowMissing {
      var info = stat()
      if lstat(root.path,&info) != 0 {
        guard errno == ENOENT else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
        try validateMissingParents(root)
        absentRoot = root
        try files.write(Data(),name:"0.conf"); return "0.conf"
      }
    }
    return try copy(root,depth:0)
  }
  func validateSources() throws {
    if let absentRoot {
      try Task.checkCancellation(); var info = stat()
      guard lstat(absentRoot.path,&info) != 0, errno == ENOENT else { throw NativeSSHConfigurationSnapshotIssue.changed }
      do { try validateMissingParents(absentRoot) }
      catch is NativeSSHConfigurationSnapshotIssue { throw NativeSSHConfigurationSnapshotIssue.changed }
    }
    for (path,revision) in revisions {
      try Task.checkCancellation(); var current = stat()
      guard lstat(path,&current) == 0, same(revision,current) else { throw NativeSSHConfigurationSnapshotIssue.changed }
    }
  }
  func copy(_ url: URL, depth: Int) throws -> String {
    guard depth <= 8 else { throw NativeSSHConfigurationSnapshotIssue.limit }
    let (info,bytes) = try read(url), id = "\(info.st_dev):\(info.st_ino)"
    if let revision = revisions[url.path], !same(revision,info) { throw NativeSSHConfigurationSnapshotIssue.changed }
    revisions[url.path] = info
    guard !active.contains(id) else { throw NativeSSHConfigurationSnapshotIssue.invalid }
    if let source = sources[id] {
      guard same(source.info,info), source.bytes == bytes else { throw NativeSSHConfigurationSnapshotIssue.changed }
      return source.name
    }
    guard sources.count < 32, totalBytes + bytes.count <= 262144,
          let text = String(data:bytes,encoding:.utf8), !bytes.contains(0) else { throw NativeSSHConfigurationSnapshotIssue.limit }
    totalBytes += bytes.count; active.insert(id); defer { active.remove(id) }
    let name = "\(sources.count).conf"
    sources[id] = Source(info:info,bytes:bytes,name:name)
    var result = ""
    for raw in text.split(separator:"\n",omittingEmptySubsequences:false) {
      try Task.checkCancellation()
      let line = String(raw).trimmingCharacters(in:CharacterSet(charactersIn:" \t\r"))
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard !line.unicodeScalars.contains(where:{ $0.value < 32 && $0.value != 9 }), line.utf8.count <= 8192 else {
        throw NativeSSHConfigurationSnapshotIssue.invalid
      }
      let key = String(line.prefix(while:{ $0 != " " && $0 != "\t" && $0 != "=" })).lowercased()
      var arguments = String(line.dropFirst(key.count)).trimmingCharacters(in:CharacterSet(charactersIn:" \t"))
      if arguments.hasPrefix("=") { arguments = String(arguments.dropFirst()).trimmingCharacters(in:CharacterSet(charactersIn:" \t")) }
      guard !key.isEmpty, !arguments.isEmpty else { throw NativeSSHConfigurationSnapshotIssue.invalid }
      if key == "include" {
        // Escaped glob syntax needs a separate lexer that preserves glob escapes.
        guard !arguments.contains("\\") else { throw NativeSSHConfigurationSnapshotIssue.unsupported }
        let patterns = try words(arguments); guard !patterns.isEmpty else { throw NativeSSHConfigurationSnapshotIssue.invalid }
        for pattern in patterns {
          let matches = try expand(pattern)
          for match in matches {
            references += 1; guard references <= 128 else { throw NativeSSHConfigurationSnapshotIssue.limit }
            let child = try copy(URL(fileURLWithPath:match),depth:depth+1)
            result += "Include \"\(files.path)/\(child)\"\n"
          }
        }
      } else if key == "match" {
        let tokens = try words(arguments); var index = 0
        guard !tokens.isEmpty else { throw NativeSSHConfigurationSnapshotIssue.invalid }
        while index < tokens.count {
          let condition = tokens[index].lowercased().drop(while:{ $0 == "!" }); index += 1
          if ["all","canonical","final"].contains(condition) { continue }
          guard ["host","originalhost","user","localuser","tagged","command"].contains(condition), index < tokens.count else {
            throw NativeSSHConfigurationSnapshotIssue.unsupported
          }
          index += 1
        }
        result += line + "\n"
      } else {
        guard Self.allowed.contains(key) else { throw NativeSSHConfigurationSnapshotIssue.unsupported }
        result += line + "\n"
      }
    }
    guard result.utf8.count <= 131072 else { throw NativeSSHConfigurationSnapshotIssue.limit }
    try files.write(Data(result.utf8),name:name); return name
  }
  // Only Include/Match need tokenization. OpenSSH still validates option values.
  private func words(_ value: String) throws -> [String] {
    var result: [String] = [], word = "", quote: Character?, escaped = false, started = false
    for character in value {
      if escaped { word.append(character); escaped = false; started = true; continue }
      if character == "\\" { escaped = true; started = true; continue }
      if let current = quote {
        if character == current { quote = nil } else { word.append(character) }; started = true; continue
      }
      if character == "\"" || character == "'" { quote = character; started = true; continue }
      if character == "#" && !started { break }
      if character == " " || character == "\t" {
        if started { result.append(word); word = ""; started = false }
      } else { word.append(character); started = true }
    }
    guard quote == nil, !escaped else { throw NativeSSHConfigurationSnapshotIssue.invalid }
    if started { result.append(word) }; return result
  }
  private func expand(_ pattern: String) throws -> [String] {
    try validURL(includeBase); try validURL(home)
    guard !pattern.isEmpty, !pattern.contains("%"), !pattern.contains("$"), !pattern.contains("\\") else { throw NativeSSHConfigurationSnapshotIssue.unsupported }
    let absolute: String
    if pattern.hasPrefix("~/") { absolute = home.path + "/" + pattern.dropFirst(2) }
    else if pattern.hasPrefix("~") { throw NativeSSHConfigurationSnapshotIssue.unsupported }
    else { absolute = pattern.hasPrefix("/") ? pattern : includeBase.path + "/" + pattern }
    let components = absolute.split(separator:"/").map(String.init)
    guard absolute.utf8.count <= 4096, components.count <= 32 else { throw NativeSSHConfigurationSnapshotIssue.limit }
    var candidates = [""]
    for component in components {
      try Task.checkCancellation(); var next: [String] = []
      for parent in candidates {
        if component.contains("*") || component.contains("?") || component.contains("[") {
          guard let directory = opendir(parent.isEmpty ? "/" : parent) else {
            if errno == ENOENT || errno == ENOTDIR { continue }
            throw NativeSSHConfigurationSnapshotIssue.unsafeFile
          }
          defer { closedir(directory) }
          while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
              guard errno == 0 else { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
              break
            }
            visitedEntries += 1; guard visitedEntries <= 4096 else { throw NativeSSHConfigurationSnapshotIssue.limit }
            let name = withUnsafePointer(to:&entry.pointee.d_name) { $0.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) } }
            if name != ".", name != "..", fnmatch(component,name,FNM_PERIOD) == 0 { next.append(parent + "/" + name) }
            guard next.count <= 32 else { throw NativeSSHConfigurationSnapshotIssue.limit }
          }
        } else { next.append(parent + "/" + component) }
      }
      candidates = next.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    var matches: [String] = []
    for path in candidates {
      try Task.checkCancellation(); var info = stat()
      if lstat(path,&info) == 0 { matches.append(path) }
      else if errno != ENOENT && errno != ENOTDIR { throw NativeSSHConfigurationSnapshotIssue.unsafeFile }
    }
    return matches
  }
}
