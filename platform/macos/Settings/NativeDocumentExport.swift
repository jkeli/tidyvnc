// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public enum NativeDocumentExportLoss: String, CaseIterable, Hashable, Sendable {
  case failureAlerts, remoteResize, networkFamilies, pointerTiming, clipboardLimit, windowPlacement, displayIdentity, ignoredInput, sshGateway
  public var description: String {
    switch self {
    case .failureAlerts: String(localized:"document.failure.alerts.omitted", defaultValue:"Failure-alert settings are not supported by this connection-file format. The receiving viewer will use its own error-alert policy.")
    case .remoteResize: String(localized:"document.remote.resize.settings.are.not.supported.by.this.connection.file.format.the", defaultValue:"Remote-resize settings are not supported by this connection-file format. The receiving viewer will use its own settings.")
    case .networkFamilies: String(localized:"document.ipv4.and.ipv6.settings.are.not.supported.by.this.connection.file.format", defaultValue:"IPv4 and IPv6 settings are not supported by this connection-file format. The receiving viewer will use its own IP version settings.")
    case .pointerTiming: String(localized:"document.pointer.event.timing.is.not.supported.by.this.connection.file.format.the", defaultValue:"Pointer-event timing is not supported by this connection-file format. The receiving viewer will use its own pointer timing.")
    case .clipboardLimit: String(localized:"document.the.incoming.clipboard.size.limit.is.not.supported.by.this.connection.file", defaultValue:"The incoming clipboard size limit is not supported by this connection-file format. The receiving viewer will use its own limit.")
    case .windowPlacement: String(localized:"document.initial.window.size.position.and.maximization.are.not.supported.by.this.connection", defaultValue:"Initial window size, position and maximization are not supported by this connection-file format. The receiving viewer will use its own window settings.")
    case .displayIdentity: String(localized:"document.stable.display.identities.become.the.monitor.numbers.listed.in.this.review.the", defaultValue:"Stable display identities become the monitor numbers listed in this review. The receiving viewer interprets those numbers using its own display arrangement.")
    case .sshGateway: String(localized:"document.the.ssh.gateway.cannot.be.saved.in.this.connection.file.format.opening", defaultValue:"The SSH gateway cannot be saved in this connection-file format. Opening the exported file will connect directly unless you configure the SSH gateway separately.")
    case .ignoredInput: String(localized:"document.fields.ignored.when.opening.the.original.file.will.not.be.copied.to", defaultValue:"Fields ignored when opening the original file will not be copied to the exported file.")
    }
  }
}
public enum NativeDocumentExportError: Error, Equatable, Sendable, CustomStringConvertible {
  case reviewRequired, securityPolicy, displayMapping, invalidConfiguration, unavailable
  public var description: String {
    switch self {
    case .reviewRequired: String(localized:"document.review.the.settings.that.cannot.be.preserved.before.exporting", defaultValue:"Review the settings that cannot be preserved before exporting.")
    case .securityPolicy: String(localized:"document.this.file.format.cannot.preserve.the.custom.tls.priority.policy.use.a", defaultValue:"This file format cannot preserve the custom TLS priority policy. Use a native profile to retain it.")
    case .displayMapping: String(localized:"document.the.selected.displays.cannot.be.mapped.to.current.monitor.numbers.resolve.the", defaultValue:"The selected displays cannot be mapped to current monitor numbers. Resolve the display selection before exporting.")
    case .invalidConfiguration: String(localized:"document.a.connection.setting.cannot.be.represented.in.this.file.correct.it.before", defaultValue:"A connection setting cannot be represented in this file. Correct it before exporting.")
    case .unavailable: String(localized:"document.finish.the.current.connection.operation.or.settings.edit.before.exporting", defaultValue:"Finish the current connection operation or settings edit before exporting.")
    }
  }
}

// Immutable, preflighted non-secret compatibility output. Construction and review
// never open a file or mutate the supplied settings. No credential/trust-store
// object, invocation environment, unknown raw entry or arbitrary key is accepted.
public struct NativeDocumentExport: Sendable, Identifiable {
  public let id = UUID()
  public let losses: Set<NativeDocumentExportLoss>
  public let endpoint: String
  public let monitorIndices: [NativeDisplayID:Int]
  private let data: Data
  public func serializedData(acknowledging losses: Set<NativeDocumentExportLoss> = []) throws -> Data {
    guard self.losses.isSubset(of:losses) else { throw NativeDocumentExportError.reviewRequired }
    return data
  }
  public init(endpoint: String, configuration: NativeSessionConfiguration,
              inactiveCursor: NativeCursorFallback = .dot,
              legacyDisplays: [NativeDisplayID] = [], ignoredInput: Bool = false,
              monitorIndices: [NativeDisplayID:Int]? = nil, sshGateway: NativeSSHGateway? = nil) throws {
    guard configuration.tlsPriority.isEmpty else { throw NativeDocumentExportError.securityPolicy }
    guard inactiveCursor == .dot || inactiveCursor == .system,
          configuration.input.shortcutModifiers.rawValue & ~15 == 0 else { throw NativeDocumentExportError.invalidConfiguration }
    if !endpoint.isEmpty {
      do { try NativeEndpoint.validate(endpoint) }
      catch { throw NativeDocumentExportError.invalidConfiguration }
    }
    guard NativeTrustFiles.isValidPath(configuration.caFile), NativeTrustFiles.isValidPath(configuration.crlFile) else {
      throw NativeDocumentExportError.invalidConfiguration
    }
    var assignments: [NativeDocumentAssignment] = [.init("ServerName",endpoint)]
    func add(_ name: String,_ value: String) { assignments.append(.init(name,value)) }
    func flag(_ name: String,_ value: Bool) { add(name,value ? "on" : "off") }
    let choices = try NativeSecuritySelection.choices()
    let types: String
    if let requested = configuration.securityTypes {
      let names = try requested.map { id in
        guard let choice = choices.first(where:{ $0.id == id }), choice.available else { throw NativeDocumentExportError.invalidConfiguration }
        return choice.name
      }
      types = try NativeSecuritySelection(names.joined(separator:",")).canonical
    } else { types = try NativeSecuritySelection().canonical }
    add("SecurityTypes",types); add("X509CA",configuration.caFile); add("X509CRL",configuration.crlFile)
    flag("Shared",configuration.shared); flag("ReconnectOnError",configuration.reconnectOnError)
    flag("SendClipboard",configuration.clipboardSend); flag("AcceptClipboard",configuration.clipboardReceive)
    let encoding = try configuration.encoding ?? NativeEncodingOptions()
    for field in try NativeEncodingOptions.schema() where field.persistent { add(field.name,try encoding.value(for:field.id).value) }
    let input = configuration.input
    flag("ViewOnly",input.viewOnly); flag("EmulateMiddleButton",input.emulateMiddle)
    flag("FullscreenSystemKeys",input.fullscreenSystemKeys)
    let modifiers = [(UInt32(1),"Ctrl"),(2,"Shift"),(4,"Alt"),(8,"Super")]
      .filter { input.shortcutModifiers.rawValue & $0.0 != 0 }.map(\.1).joined(separator:",")
    add("ShortcutModifiers",modifiers)
    flag("AlwaysCursor",input.cursorFallback != .hidden)
    let shape = input.cursorFallback == .hidden ? inactiveCursor : input.cursorFallback
    add("CursorType",shape == .system ? "System" : "Dot")
    let scaling = configuration.scaling ?? .builtIn
    add("ScalingFactor",scaling.canonical)
    add("ScalingQuality",scaling.filter == .nearest ? "Nearest" : scaling.filter == .area ? "Area" : "Bilinear")
    add("DesktopPixelUnits",scaling.devicePixels ? "Device" : "Logical")
    let fullscreen = configuration.fullscreenPolicy
    flag("FullScreen",fullscreen.startsFullscreen)
    add("FullScreenMode",fullscreen.mode == .selected ? "Selected" : fullscreen.mode == .all ? "All" : "Current")
    // Even built-in omitted values can differ from the receiving viewer’s
    // preferences, so omission requires review for every export.
    var losses: Set<NativeDocumentExportLoss> = [.failureAlerts,.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement]
    var indices: [Int] = []
    var mapping: [NativeDisplayID:Int] = [:]
    if let monitorIndices {
      guard Set(monitorIndices.keys) == Set(fullscreen.selectedDisplays),
            Set(monitorIndices.values).count == monitorIndices.count,
            monitorIndices.values.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else { throw NativeDocumentExportError.displayMapping }
      mapping = monitorIndices
    }
    if !fullscreen.selectedDisplays.isEmpty {
      if monitorIndices == nil {
        guard legacyDisplays.count <= 64, Set(legacyDisplays).count == legacyDisplays.count else { throw NativeDocumentExportError.displayMapping }
        for id in fullscreen.selectedDisplays {
          guard let index = legacyDisplays.firstIndex(of:id) else { throw NativeDocumentExportError.displayMapping }
          mapping[id] = index+1
        }
      }
      indices = Array(mapping.values)
      losses.insert(.displayIdentity)
    }
    add("FullScreenSelectedMonitors",indices.sorted().map(String.init).joined(separator:","))
    if ignoredInput { losses.insert(.ignoredInput) }
    if sshGateway != nil { losses.insert(.sshGateway) }
    let bytes = try NativeConnectionDocument.serialize(assignments)
    // Verify every emitted field through the shared file-semantic boundary, not
    // just syntax. A future schema field absent from the file catalog fails.
    let parsed = try NativeConnectionDocument(data:bytes)
    for index in parsed.entries.indices {
      guard try parsed.validatedOption(at:index) != nil else { throw NativeDocumentExportError.invalidConfiguration }
    }
    self.endpoint = endpoint; self.losses = losses; self.monitorIndices = mapping; data = bytes
  }
}
