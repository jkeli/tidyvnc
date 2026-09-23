// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Manual fixture for tests/integration/macos-rollback-smoke.py: writes a
// reviewed compatibility connection file through the production
// NativeDocumentExport codec (the same bytes File > Save Connection File As
// produces after review), with the given endpoint, security types and
// PreferredEncoding=Hextile, AutoSelect=0 and clipboard sharing off. Not a CTest case.
//   native-export-fixture <endpoint> <SecurityTypes> <output>
import Foundation
import TidyVNCNative

struct UnknownSecurity: Error { let name: String }
@main struct ExportFixture {
  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else {
      FileHandle.standardError.write(Data("usage: native-export-fixture <endpoint> <SecurityTypes> <output>\n".utf8)); exit(2)
    }
    do {
      var configuration = NativeSessionConfiguration()
      configuration.encoding = try NativeEncodingOptions(patch: [.init("AutoSelect", "0"), .init("PreferredEncoding", "Hextile")])
      // Clipboard sharing off: the receiving viewer must not touch the real pasteboard.
      configuration.clipboardSend = false; configuration.clipboardReceive = false
      let names = try NativeSecuritySelection.choices()
      configuration.securityTypes = try arguments[2].split(separator: ",").map { name in
        guard let choice = names.first(where: { $0.name.caseInsensitiveCompare(String(name)) == .orderedSame }) else {
          throw UnknownSecurity(name: String(name))
        }
        return choice.id
      }
      let export = try NativeDocumentExport(endpoint: arguments[1], configuration: configuration)
      try export.serializedData(acknowledging: export.losses).write(to: URL(fileURLWithPath: arguments[3]))
      print("wrote \(arguments[3]) acknowledging \(export.losses.count) reviewed omissions")
    } catch { FileHandle.standardError.write(Data("export failed: \(error)\n".utf8)); exit(1) }
  }
}
