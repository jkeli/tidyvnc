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
      title:mapping.monitorSource == .commandLine ? String(localized:"document.choose.displays.for.command.line.options", defaultValue:"Choose Displays for Command-Line Options") : String(localized:"document.choose.displays.for.this.file", defaultValue:"Choose Displays for This File"),
      explanation:mapping.monitorSource == .commandLine ? String(localized:"document.the.connection.file.inherits.these.command.line.monitor.numbers.choose.which.connected", defaultValue:"The connection file inherits these command-line monitor numbers. Choose which connected display each number should use.") : String(localized:"document.monitor.numbers.belong.to.the.computer.that.saved.the.file.choose.which", defaultValue:"Monitor numbers belong to the computer that saved the file. Choose which connected display each number should use here."),
      commandLine:mapping.monitorSource == .commandLine,prefix:"document",actionTitle:String(localized:"document.review.connection", defaultValue:"Review Connection"),
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
      title:String(localized:"document.choose.displays.for.command.line.options", defaultValue:"Choose Displays for Command-Line Options"),
      explanation:String(localized:"document.choose.which.connected.display.each.command.line.monitor.number.should.use.for", defaultValue:"Choose which connected display each command-line monitor number should use for this connection."),
      commandLine:true,prefix:"invocation",actionTitle:mapping.endpoint.isEmpty ? String(localized:"profiles.open.connection", defaultValue:"Open Connection") : String(localized:"document.connect", defaultValue:"Connect"),
      resolve:resolve,cancel:cancel)
  }
}
private struct MonitorMappingForm: View {
  let numbers: [Int], suggested: [Int:NativeDisplayID]
  @ObservedObject var displays: NativeDisplayService
  let issue: String?
  let title: String, explanation: String
  let commandLine: Bool
  let prefix: String, actionTitle: String
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
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          Text(explanation)
          VStack(alignment:.leading,spacing:12) {
            ForEach(numbers,id:\.self) { number in
              let label = commandLine ? String(localized:"document.monitor.commandline.label", defaultValue:"Command-line monitor \(number.formatted())") : String(localized:"document.monitor.file.label", defaultValue:"File monitor \(number.formatted())")
              Text(label).fixedSize(horizontal:false,vertical:true)
              Picker(label,selection:selection(number)) {
                Text(String(localized:"document.choose.a.display", defaultValue:"Choose a display")).tag(nil as String?)
                ForEach(displays.snapshot.displays,id:\.id) { display in
                  Text(display.name).tag(display.id.rawValue as String?)
                }
                if let id = choices.assignments[number], displays.snapshot.display(id) == nil {
                  Text(String(localized:"document.disconnected.display", defaultValue:"Disconnected display")).tag(id.rawValue as String?)
                }
              }.labelsHidden().accessibilityLabel(label).accessibilityIdentifier(prefix+".mapping.monitor.\(number)")
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
          Text(String(localized:"document.several.monitor.numbers.may.use.the.same.display.that.display.will.be", defaultValue:"Several monitor numbers may use the same display; that display will be used once. This choice applies only to this connection and does not change saved settings."))
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
      if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
      else if displays.snapshot.error != nil || displays.snapshot.displays.isEmpty {
        Text(String(localized:"document.display.information.is.unavailable.connect.a.display.and.refresh.before.continuing", defaultValue:"Display information is unavailable. Connect a display and refresh before continuing."))
          .foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
      }
      Button(String(localized:"document.refresh.displays", defaultValue:"Refresh Displays")) { displays.refresh() }
      HStack {
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),action:cancel).keyboardShortcut(.cancelAction)
        Spacer()
        Button(actionTitle) { resolve(choices.assignments) }.disabled(!complete)
          .keyboardShortcut(.defaultAction).accessibilityIdentifier(prefix+".mapping.review")
      }
    }.frame(maxWidth:620)
      .onAppear { choices.assignments = suggested; displays.refresh() }
  }
}
