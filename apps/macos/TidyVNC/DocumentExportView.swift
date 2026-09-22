// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct DocumentExportView: View {
  let export: NativeDocumentExport
  var displayNames: [NativeDisplayID:String] = [:]
  var editMapping: (() -> Void)? = nil
  let approve: () -> Void
  let cancel: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"document.review.connection.export", defaultValue:"Review Connection Export")).font(.title2).accessibilityIdentifier("document.export.title")
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          Text(export.endpoint.isEmpty ? String(localized:"document.this.file.will.contain.settings.without.a.server.address", defaultValue:"This file will contain settings without a server address.") : String(localized:"document.server", defaultValue:"Server: \(export.endpoint)"))
            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
          Text(String(localized:"document.the.file.will.contain.a.snapshot.of.this.connection.s.settings.passwords", defaultValue:"The file will contain a snapshot of this connection's settings. Passwords and saved trust decisions are excluded."))
            .fixedSize(horizontal:false,vertical:true)
          if !export.monitorIndices.isEmpty {
            Text(String(localized:"document.display.numbers.in.the.exported.file", defaultValue:"Display numbers in the exported file")).font(.headline)
            VStack(alignment:.leading,spacing:8) {
              ForEach(export.monitorIndices.keys.sorted { $0.rawValue < $1.rawValue },id:\.self) { id in
                VStack(alignment:.leading,spacing:4) {
                  Text(String(localized:"document.export.monitor.assignment", defaultValue:"\(displayNames[id] ?? String(localized:"document.saved.display", defaultValue:"Saved display")): monitor \(export.monitorIndices[id]!.formatted())"))
                    .fixedSize(horizontal:false,vertical:true)
                  if displayNames[id] == nil { Text(id.rawValue).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                }
              }
            }
            if let editMapping {
              Button(String(localized:"document.change.exported.monitor.numbers", defaultValue:"Change Exported Monitor Numbers…"),action:editMapping).accessibilityIdentifier("document.export.editMapping")
            }
          }
          if !export.losses.isEmpty {
            Text(String(localized:"document.settings.the.file.cannot.preserve", defaultValue:"Settings the file cannot preserve")).font(.headline)
            ForEach(NativeDocumentExportLoss.allCases.filter { export.losses.contains($0) },id:\.self) { loss in
              Text(loss.description).fixedSize(horizontal:false,vertical:true)
            }
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("document.export.details")
      HStack {
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel,action:cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("document.export.cancel")
        Spacer()
        Button(String(localized:"document.continue.to.save", defaultValue:"Continue to Save…"),action:approve).keyboardShortcut(.defaultAction).accessibilityIdentifier("document.export.approve")
      }
    }.padding(24).frame(width:560)
  }
}

struct DocumentExportMappingView: View {
  let mapping: NativeDocumentExportMapping
  let issue: String?
  let resolve: ([NativeDisplayID:Int]) -> Void
  let cancel: () -> Void
  @MainActor private final class Choices: ObservableObject {
    @Published var numbers: [NativeDisplayID:String] = [:]
  }
  @StateObject private var choices = Choices()
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"document.choose.exported.monitor.numbers", defaultValue:"Choose Exported Monitor Numbers")).font(.title2).accessibilityIdentifier("document.export.mapping.title")
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          Text(String(localized:"document.the.file.format.uses.monitor.numbers.instead.of.saved.display.identities.assign", defaultValue:"The file format uses monitor numbers instead of saved display identities. Assign the numbers the receiving viewer should use, including for displays currently disconnected from this Mac."))
          VStack(alignment:.leading,spacing:12) {
            ForEach(mapping.selectedDisplays,id:\.self) { id in
              VStack(alignment:.leading,spacing:4) {
                Text(mapping.displayNames[id] ?? String(localized:"document.saved.display", defaultValue:"Saved display")).font(.headline)
                TextField(mapping.displayNames[id] ?? String(localized:"document.saved.display", defaultValue:"Saved display"),text:Binding(
                  get:{ choices.numbers[id] ?? "" },set:{ choices.numbers[id] = $0 }))
                  .textFieldStyle(.roundedBorder).accessibilityIdentifier("document.export.mapping."+id.rawValue)
                if mapping.displayNames[id] == nil { Text(id.rawValue).font(.caption).textSelection(.enabled) }
              }
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
          Text(String(localized:"document.use.a.different.positive.whole.number.for.each.display.these.choices.affect", defaultValue:"Use a different positive whole number for each display. These choices affect only the exported file; this connection keeps its selected displays."))
            .font(.caption).foregroundStyle(.secondary)
          if let issue { Text(issue).foregroundStyle(.red) }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
      HStack {
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),action:cancel).keyboardShortcut(.cancelAction)
        Spacer()
        Button(String(localized:"document.review.export", defaultValue:"Review Export")) {
          if let indices = try? mapping.indices(from:choices.numbers) { resolve(indices) }
        }.disabled((try? mapping.indices(from:choices.numbers)) == nil)
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("document.export.mapping.review")
      }
    }.padding(24).frame(width:560)
      .onAppear { choices.numbers = Dictionary(uniqueKeysWithValues:mapping.selectedDisplays.map { ($0,mapping.suggestedIndices[$0].map(String.init) ?? "") }) }
  }
}

// One sheet identity spans mapping and final review. Changing an inner review
// UUID must not dismiss a sheet and race the destination-panel handoff.
struct DocumentSaveReviewView: View {
  @ObservedObject var state: NativeDocumentSaveState
  var body: some View {
    Group {
      if let mapping = state.mapping {
        DocumentExportMappingView(mapping:mapping,issue:state.issue,
          resolve:{ state.resolveMapping(mapping.id,indices:$0) },cancel:{ state.cancel(mapping.id) }).id(mapping.id)
      } else if let export = state.review {
        DocumentExportView(export:export,displayNames:state.displayNames,
          editMapping:state.canEditMapping ? { state.editMapping(export.id) } : nil,
          approve:{ state.approve(export.id) },cancel:{ state.cancel(export.id) })
      }
    }.frame(width:560,height:600,alignment:.top)
      .background(Color(nsColor:.windowBackgroundColor))
  }
}
struct DocumentSaveStatusView: View {
  @ObservedObject var state: NativeDocumentSaveState
  var body: some View {
    if state.isWriting { ProgressView(String(localized:"document.saving.connection.file", defaultValue:"Saving connection file…")).padding(8).accessibilityIdentifier("document.save.progress") }
    else if let issue = state.issue {
      HStack { Text(issue).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("document.save.error")
        Button(String(localized:"document.dismiss", defaultValue:"Dismiss")) { state.dismissResult() }
      }.padding(8)
    } else if let url = state.savedURL {
      HStack { Text(String(localized:"document.save.success", defaultValue:"Saved \(url.lastPathComponent)")).accessibilityIdentifier("document.save.success")
        Button(String(localized:"document.dismiss", defaultValue:"Dismiss")) { state.dismissResult() }
      }.padding(8)
    }
  }
}
