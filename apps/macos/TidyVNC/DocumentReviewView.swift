// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct DocumentReviewView: View {
  let review: NativeDocumentReview
  @ObservedObject var displays: NativeDisplayService
  let editMapping: () -> Void
  let accept: () -> Void
  let cancel: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text("Review Connection File").font(.title2).accessibilityIdentifier("document.review.title")
      Text(review.resolution.endpoint.isEmpty ? "No server address is stored in this file. Enter one after opening." : "Server: \(review.resolution.endpoint)")
        .textSelection(.enabled)
      Text("File settings override saved defaults for this new connection. Opening does not connect or change saved preferences.")
      if !review.resolution.notices.isEmpty {
        Text("These fields will be ignored:").font(.headline)
        ScrollView {
          VStack(alignment:.leading,spacing:6) {
            ForEach(review.resolution.notices,id:\.line) { notice in
              Text("Line \(notice.line): \(notice.name) — \(notice.kind == .platformOnly ? "Unavailable on macOS" : "Unknown field")")
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
        }.frame(maxHeight:180)
      }
      let numbers = review.resolution.monitorNumbers
      if !numbers.isEmpty {
        Text("Displays for this connection").font(.headline)
        ScrollView {
          VStack(alignment:.leading,spacing:6) {
            ForEach(numbers,id:\.self) { number in
              let id = review.resolution.resolvedMonitorMapping[number]
              Text("\(review.resolution.monitorSource == .commandLine ? "Command-line" : "File") monitor \(number): \(id.flatMap { displays.snapshot.display($0)?.name } ?? "Unavailable display")")
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
        }.frame(maxHeight:150)
        Text(review.monitorMapping == nil ? "These assignments follow the current display arrangement, left to right and then top to bottom. Change them if this file came from another arrangement." : "These are the display assignments you chose for this connection.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Change Display Assignments…",action:editMapping).accessibilityIdentifier("document.mapping.edit")
      }
      HStack {
        Button("Cancel",role:.cancel,action:cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("document.cancel")
        Spacer()
        Button(review.resolution.notices.isEmpty ? "Open Connection" : "Ignore Listed Fields and Open",action:accept)
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("document.accept")
      }
    }.frame(maxWidth:620)
  }
}
