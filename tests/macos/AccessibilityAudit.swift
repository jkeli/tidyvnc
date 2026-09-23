// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Accessibility-API client for tests/macos/accessibility-audit.py. It reads the
// accessibility tree of one running app (the process must be an accessibility
// client) and performs AXPress/AXValue actions only: no synthetic mouse or
// keyboard input, and the app is never activated. Commands run in order:
//   wait ID                 until an element with that identifier/title exists
//   press ID                AXPress the first matching element
//   set ID VALUE            set AXValue (text fields)
//   menu TOP ITEM           press a menu-bar item
//   choose POPUP PREFIX     for each item of a pop-up or segmented picker: choose it, then audit
//   confirm ID              AXConfirm (the accessibility equivalent of Return)
//   value ID                print the element's AXValue as a JSON line
//   audit NAME              print one JSON line describing interactive elements
//   menuitem BUTTON ITEM    open a menu button and press one of its items
//   close-others TITLE      close every window except the one with that title
//   close TITLE             press the close button of the window with that title
//   sleep MS
// Matching is exact on AXIdentifier, AXTitle or AXDescription.
import AppKit
import ApplicationServices

struct Failure: Error, CustomStringConvertible { let description: String }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String? {
  (attribute(element, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
}
func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ element: AXUIElement) -> [Int] {
  var origin = CGPoint.zero, size = CGSize.zero
  if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
  if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
  return [Int(origin.x), Int(origin.y), Int(size.width), Int(size.height)]
}

let interactiveRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
  "AXTextField", "AXTextArea", "AXSlider", "AXIncrementor", "AXComboBox", "AXLink", "AXDisclosureTriangle",
  "AXSegmentedControl", "AXTabGroup", "AXColorWell", "AXSearchField"]
// System window, stepper and scroll-bar parts that VoiceOver names from their subrole.
let namedSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
  "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage", "AXToolbarButton"]

func label(_ element: AXUIElement) -> String? {
  if let title = string(element, kAXTitleAttribute) { return title }
  if let description = string(element, kAXDescriptionAttribute) { return description }
  if let titleElement = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(titleElement) == AXUIElementGetTypeID() {
    if let value = string(titleElement as! AXUIElement, kAXValueAttribute) { return value }
  }
  if let placeholder = string(element, kAXPlaceholderValueAttribute) { return placeholder }
  if let help = string(element, kAXHelpAttribute) { return help }
  return nil
}

final class Auditor {
  let app: AXUIElement
  init(pid: pid_t) { app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 5) }
  var windows: [AXUIElement] { (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
  func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(element) { return true }
    guard depth < 60 else { return false }
    for child in children(element) where walk(child, depth: depth + 1, visit) { return true }
    return false
  }
  func find(_ key: String) -> AXUIElement? {
    var match: AXUIElement?
    for window in windows {
      if walk(window, { element in
        let hit = string(element, kAXIdentifierAttribute) == key || string(element, kAXTitleAttribute) == key
          || string(element, kAXDescriptionAttribute) == key
        if hit && string(element, kAXRoleAttribute) != "AXStaticText" { match = element }
        return match != nil
      }) { break }
    }
    return match
  }
  func waitFor(_ key: String, seconds: Double = 10) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if let element = find(key) { return element }
      usleep(100_000)
    }
    throw Failure(description: "no element \(key)")
  }
  func press(_ element: AXUIElement, _ key: String) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
      throw Failure(description: "AXPress \(key) (\(string(element, kAXRoleAttribute) ?? "?")) failed: \(result.rawValue)")
    }
    usleep(300_000)
  }
  func menu(_ top: String, _ item: String) throws {
    guard let bar = attribute(app, kAXMenuBarAttribute) else { throw Failure(description: "no menu bar") }
    let barElement = bar as! AXUIElement
    guard let topItem = children(barElement).first(where: { string($0, kAXTitleAttribute) == top }),
          let menu = children(topItem).first,
          let entry = children(menu).first(where: { string($0, kAXTitleAttribute) == item }) else {
      throw Failure(description: "no menu item \(top) › \(item)")
    }
    guard (attribute(entry, kAXEnabledAttribute) as? Bool) != false else { throw Failure(description: "menu item \(top) › \(item) is disabled") }
    try press(entry, "\(top) › \(item)")
  }
  func choose(_ key: String, then audit: (String) -> Void) throws {
    let popup = try waitFor(key)
    if ["AXRadioGroup", "AXTabGroup", "AXSegmentedControl"].contains(string(popup, kAXRoleAttribute) ?? "") {
      // Segmented pickers: press each segment in turn.
      var segments: [AXUIElement] = []
      _ = walk(popup) { element in
        if string(element, kAXRoleAttribute) == "AXRadioButton" { segments.append(element) }
        return false
      }
      for segment in segments {
        let title = label(segment) ?? "?"
        try press(segment, title); audit(title)
      }
      return
    }
    try press(popup, key)
    guard let menu = children(popup).first else { throw Failure(description: "pop-up \(key) has no menu") }
    let titles = children(menu).compactMap { string($0, kAXTitleAttribute) }
    _ = AXUIElementPerformAction(popup, kAXCancelAction as CFString); usleep(200_000)
    for title in titles {
      let popup = try waitFor(key)
      try press(popup, key)
      guard let item = children(children(popup).first ?? popup).first(where: { string($0, kAXTitleAttribute) == title }) else {
        throw Failure(description: "pop-up \(key) lost item \(title)")
      }
      try press(item, title); usleep(300_000)
      audit(title)
    }
  }
  func audit(_ name: String) {
    var interactive = 0, unlabeled: [[String: Any]] = [], system: [[String: Any]] = [], titles: [String] = []
    for window in windows {
      titles.append(string(window, kAXTitleAttribute) ?? "")
      _ = walk(window) { element in
        guard let role = string(element, kAXRoleAttribute), interactiveRoles.contains(role) else { return false }
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        interactive += 1
        if label(element) == nil && !namedSubroles.contains(subrole) {
          let identifier = string(element, kAXIdentifierAttribute) ?? "", value = (attribute(element, kAXValueAttribute) as? String) ?? ""
          let entry: [String: Any] = ["role": role, "subrole": subrole, "identifier": identifier, "value": String(value.prefix(80)),
                                      "frame": frame(element)]
          // AppKit-provided text (e.g. the standard About panel's credits) speaks its
          // content and cannot be labeled by the app; report it separately.
          if identifier.hasPrefix("_NS:") && !value.isEmpty && ["AXTextArea", "AXTextField"].contains(role) { system.append(entry) }
          else { unlabeled.append(entry) }
        }
        return false
      }
    }
    let line: [String: Any] = ["audit": name, "windows": titles, "interactive": interactive, "unlabeled": unlabeled, "system": system]
    print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
  }
  func close(_ title: String) throws {
    guard let window = windows.first(where: { string($0, kAXTitleAttribute) == title }),
          let button = attribute(window, kAXCloseButtonAttribute) else { throw Failure(description: "no window \(title)") }
    try press(button as! AXUIElement, "close \(title)")
  }
}

guard AXIsProcessTrusted() else { FileHandle.standardError.write(Data("not an accessibility client\n".utf8)); exit(3) }
var arguments = Array(CommandLine.arguments.dropFirst())
guard let pid = arguments.first.flatMap({ pid_t($0) }) else { FileHandle.standardError.write(Data("usage: accessibility-audit PID COMMAND...\n".utf8)); exit(2) }
arguments.removeFirst()
let auditor = Auditor(pid: pid)
func take() throws -> String {
  guard !arguments.isEmpty else { throw Failure(description: "missing argument") }
  return arguments.removeFirst()
}
do {
  while !arguments.isEmpty {
    let command = arguments.removeFirst()
    switch command {
    case "wait": _ = try auditor.waitFor(try take())
    case "press": let key = try take(); try auditor.press(try auditor.waitFor(key), key)
    case "set":
      let key = try take(), value = try take(), element = try auditor.waitFor(key)
      let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
      guard result == .success else { throw Failure(description: "set \(key) failed: \(result.rawValue)") }
      usleep(200_000)
    case "menu": let top = try take(); try auditor.menu(top, try take())
    case "choose": let key = try take(), prefix = try take(); try auditor.choose(key) { auditor.audit(prefix + ":" + $0) }
    case "value":
      let key = try take(), element = try auditor.waitFor(key)
      print("{\"value\": \"\(key)\", \"text\": \"\((attribute(element, kAXValueAttribute) as? String) ?? "")\"}"); fflush(stdout)
    case "confirm":
      let key = try take(), element = try auditor.waitFor(key)
      let result = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
      guard result == .success else { throw Failure(description: "AXConfirm \(key) failed: \(result.rawValue)") }
      usleep(300_000)
    case "menuitem":
      let key = try take(), item = try take(), button = try auditor.waitFor(key)
      try auditor.press(button, key)
      guard let entry = children(children(button).first ?? button).first(where: { string($0, kAXTitleAttribute) == item }) else {
        throw Failure(description: "no item \(item) in \(key)")
      }
      try auditor.press(entry, item)
    case "close-others":
      let keep = try take()
      for window in auditor.windows where string(window, kAXTitleAttribute) != keep {
        if let button = attribute(window, kAXCloseButtonAttribute) { try auditor.press(button as! AXUIElement, "close") }
      }
    case "audit": auditor.audit(try take())
    case "close": try auditor.close(try take())
    case "sleep": usleep(useconds_t((Int(try take()) ?? 0) * 1000))
    default: throw Failure(description: "unknown command \(command)")
    }
  }
} catch {
  print("{\"error\": \"\(error)\"}"); fflush(stdout); exit(1)
}
