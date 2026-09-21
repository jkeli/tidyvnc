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
      Text("Review Connection Export").font(.title2).accessibilityIdentifier("document.export.title")
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          Text(export.endpoint.isEmpty ? "This file will contain settings without a server address." : "Server: \(export.endpoint)")
            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
          Text("The file will contain a snapshot of this connection's settings. Passwords and saved trust decisions are excluded.")
            .fixedSize(horizontal:false,vertical:true)
          if !export.monitorIndices.isEmpty {
            Text("Display numbers in the exported file").font(.headline)
            VStack(alignment:.leading,spacing:8) {
              ForEach(export.monitorIndices.keys.sorted { $0.rawValue < $1.rawValue },id:\.self) { id in
                VStack(alignment:.leading,spacing:4) {
                  Text("\(displayNames[id] ?? "Saved display"): monitor \(export.monitorIndices[id]!)")
                    .fixedSize(horizontal:false,vertical:true)
                  if displayNames[id] == nil { Text(id.rawValue).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                }
              }
            }
            if let editMapping {
              Button("Change Exported Monitor Numbers…",action:editMapping).accessibilityIdentifier("document.export.editMapping")
            }
          }
          if !export.losses.isEmpty {
            Text("Settings the file cannot preserve").font(.headline)
            ForEach(NativeDocumentExportLoss.allCases.filter { export.losses.contains($0) },id:\.self) { loss in
              Text(loss.description).fixedSize(horizontal:false,vertical:true)
            }
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("document.export.details")
      HStack {
        Button("Cancel",role:.cancel,action:cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("document.export.cancel")
        Spacer()
        Button("Continue to Save…",action:approve).keyboardShortcut(.defaultAction).accessibilityIdentifier("document.export.approve")
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
      Text("Choose Exported Monitor Numbers").font(.title2).accessibilityIdentifier("document.export.mapping.title")
      Text("The file format uses monitor numbers instead of saved display identities. Assign the numbers the receiving viewer should use, including for displays currently disconnected from this Mac.")
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          ForEach(mapping.selectedDisplays,id:\.self) { id in
            VStack(alignment:.leading,spacing:4) {
              Text(mapping.displayNames[id] ?? "Saved display").font(.headline)
              TextField(mapping.displayNames[id] ?? "Saved display",text:Binding(
                get:{ choices.numbers[id] ?? "" },set:{ choices.numbers[id] = $0 }))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("document.export.mapping."+id.rawValue)
              if mapping.displayNames[id] == nil { Text(id.rawValue).font(.caption).textSelection(.enabled) }
            }
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(maxHeight:220)
      Text("Use a different positive whole number for each display. These choices affect only the exported file; this connection keeps its selected displays.")
        .font(.caption).foregroundStyle(.secondary)
      if let issue { Text(issue).foregroundStyle(.red) }
      HStack {
        Button("Cancel",action:cancel).keyboardShortcut(.cancelAction)
        Spacer()
        Button("Review Export") {
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
    if state.isWriting { ProgressView("Saving connection file…").padding(8).accessibilityIdentifier("document.save.progress") }
    else if let issue = state.issue {
      HStack { Text(issue).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("document.save.error")
        Button("Dismiss") { state.dismissResult() }
      }.padding(8)
    } else if let url = state.savedURL {
      HStack { Text("Saved \(url.lastPathComponent)").accessibilityIdentifier("document.save.success")
        Button("Dismiss") { state.dismissResult() }
      }.padding(8)
    }
  }
}
