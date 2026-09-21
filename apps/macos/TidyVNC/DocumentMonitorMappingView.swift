// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct DocumentMonitorMappingView: View {
  let mapping: NativeDocumentMonitorMapping
  @ObservedObject var displays: NativeDisplayService
  let issue: String?
  let resolve: ([Int:NativeDisplayID]) -> Void
  let cancel: () -> Void
  var body: some View {
    MonitorMappingForm(numbers:mapping.numbers,suggested:mapping.suggested,displays:displays,issue:issue,
      title:mapping.monitorSource == .commandLine ? "Choose Displays for Command-Line Options" : "Choose Displays for This File",
      explanation:mapping.monitorSource == .commandLine ? "The connection file inherits these command-line monitor numbers. Choose which connected display each number should use." : "Monitor numbers belong to the computer that saved the file. Choose which connected display each number should use here.",
      label:mapping.monitorSource == .commandLine ? "Command-line" : "File",prefix:"document",actionTitle:"Review Connection",
      resolve:resolve,cancel:cancel)
  }
}
struct InvocationMonitorMappingView: View {
  let mapping: NativeInvocationMonitorMapping
  @ObservedObject var displays: NativeDisplayService
  let issue: String?
  let resolve: ([Int:NativeDisplayID]) -> Void
  let cancel: () -> Void
  var body: some View {
    MonitorMappingForm(numbers:mapping.numbers,suggested:mapping.suggested,displays:displays,issue:issue,
      title:"Choose Displays for Command-Line Options",
      explanation:"Choose which connected display each command-line monitor number should use for this connection.",
      label:"Command-line",prefix:"invocation",actionTitle:mapping.endpoint.isEmpty ? "Open Connection" : "Connect",
      resolve:resolve,cancel:cancel)
  }
}
private struct MonitorMappingForm: View {
  let numbers: [Int], suggested: [Int:NativeDisplayID]
  @ObservedObject var displays: NativeDisplayService
  let issue: String?
  let title: String, explanation: String, label: String, prefix: String, actionTitle: String
  let resolve: ([Int:NativeDisplayID]) -> Void
  let cancel: () -> Void
  @MainActor private final class Choices: ObservableObject {
    @Published var assignments: [Int:NativeDisplayID] = [:]
  }
  @StateObject private var choices = Choices()
  private func selection(_ number: Int) -> Binding<String?> {
    Binding(get:{ choices.assignments[number]?.rawValue },set:{ choices.assignments[number] = $0.map(NativeDisplayID.init) })
  }
  private var complete: Bool {
    !numbers.isEmpty && displays.snapshot.error == nil && numbers.allSatisfy {
      guard let id = choices.assignments[$0] else { return false }
      return displays.snapshot.display(id) != nil
    }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(title).font(.title2).accessibilityIdentifier(prefix+".mapping.title")
      Text(explanation)
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          ForEach(numbers,id:\.self) { number in
            Picker("\(label) monitor \(number)",selection:selection(number)) {
              Text("Choose a display").tag(nil as String?)
              ForEach(displays.snapshot.displays,id:\.id) { display in
                Text(display.name).tag(display.id.rawValue as String?)
              }
              if let id = choices.assignments[number], displays.snapshot.display(id) == nil {
                Text("Disconnected display").tag(id.rawValue as String?)
              }
            }.accessibilityIdentifier(prefix+".mapping.monitor.\(number)")
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(maxHeight:300)
      Text("Several monitor numbers may use the same display; that display will be used once. This choice applies only to this connection and does not change saved settings.")
        .font(.caption).foregroundStyle(.secondary)
      if displays.snapshot.error != nil || displays.snapshot.displays.isEmpty {
        Text("Display information is unavailable. Connect a display and refresh before continuing.").foregroundStyle(.orange)
      }
      if let issue { Text(issue).foregroundStyle(.red) }
      HStack {
        Button("Cancel",action:cancel).keyboardShortcut(.cancelAction)
        Button("Refresh Displays") { displays.refresh() }
        Spacer()
        Button(actionTitle) { resolve(choices.assignments) }.disabled(!complete)
          .keyboardShortcut(.defaultAction).accessibilityIdentifier(prefix+".mapping.review")
      }
    }.frame(maxWidth:620)
      .onAppear { choices.assignments = suggested; displays.refresh() }
  }
}
