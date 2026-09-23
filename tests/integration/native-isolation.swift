// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Verify Foundation paths before launching an app copy with a unique identity.
// CFPreferences is isolated by explicit domain, not by HOME. Only domains whose
// suffix is a fixture UUID are touched, including during cleanup.
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
let prefix = "io.github.jkeli.tidyvnc.protocol-fixture."
let domain = CommandLine.arguments[2]
guard domain.hasPrefix(prefix), UUID(uuidString:String(domain.dropFirst(prefix.count))) != nil else { exit(2) }
if CommandLine.arguments[1] == "--cleanup" {
  for name in [domain,domain + ".native.preferences"] {
    let defaults = UserDefaults(suiteName:name)!
    defaults.removePersistentDomain(forName:name)
    guard defaults.synchronize() else { exit(1) }
  }
  exit(0)
}
let expected = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.resolvingSymlinksInPath()
guard home == expected, support?.path.hasPrefix(expected.path + "/") == true else {
  FileHandle.standardError.write(Data("Native fixture home/Application Support isolation failed\n".utf8))
  exit(1)
}
for name in [domain,domain + ".native.preferences"] {
  guard UserDefaults(suiteName:name)?.persistentDomain(forName:name)?.isEmpty != false else { exit(1) }
}
print("PASS isolated Foundation paths and fresh fixture preference domains")
