// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
import SwiftUI
import TidyVNCNative

@main enum TidyVNCMain {
  @MainActor static func main() {
    do {
      let arguments = try NativeInvocationArguments.read(argc:CommandLine.argc,argv:CommandLine.unsafeArgv)
      let options = try NativeInvocationOptions(arguments:arguments)
      let attribution = Bundle.main.object(forInfoDictionaryKey:"NSHumanReadableCopyright") as? String ?? ""
      if let terminal = try NativeInvocationBootstrap.terminal(options,version:NativeBuildInfo.version,copyright:attribution) {
        FileHandle.standardError.write(Data(terminal.text.utf8)); exit(terminal.exitCode)
      }
      var launch = try NativeInvocationBootstrap.launch(options,workingDirectory:FileManager.default.currentDirectoryPath,
        customTunnelCommandPresent:getenv("VNC_VIA_CMD") != nil)
      launch.credentials = try NativeLaunchCredentialInputs.capture(passwordFile:
        NativeLaunchCredentialInputs.passwordFile(options,workingDirectory:launch.invocation.workingDirectory))
      try NativeProcessLogging.start(options)
      TidyVNCLaunchContext.startup = NativeInvocationStartup(launch)
      TidyVNCApp.main()
    } catch let error as NativeLaunchCredentialIssue {
      fail(error.description)
    } catch let error as NativeInvocationFailure {
      fail(error.description)
    } catch let error as NativeInvocationResolutionFailure {
      fail(error.description)
    } catch {
      fail(String(localized:"invocation.error.initialize", defaultValue:"Unable to initialize the native command line."))
    }
  }
  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("vncviewer: "+message+"\n").utf8)); exit(1)
  }
}
