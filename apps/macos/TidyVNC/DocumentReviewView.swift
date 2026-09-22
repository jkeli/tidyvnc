// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct DocumentReviewView: View {
  let review: NativeDocumentReview
  @ObservedObject var displays: NativeDisplayService
  let editMapping: () -> Void
  let accept: () -> Void
  let cancel: () -> Void
  var listening = false
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"document.review.connection.file", defaultValue:"Review Connection File")).font(.title2).accessibilityIdentifier("document.review.title")
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          Text(listening ? String(localized:"document.listen.port", defaultValue:"TCP listen port: \(review.resolution.endpoint.isEmpty ? "5500" : review.resolution.endpoint)") :
            (review.resolution.endpoint.isEmpty ? String(localized:"document.no.server.address.is.stored.in.this.file.enter.one.after.opening", defaultValue:"No server address is stored in this file. Enter one after opening.") : String(localized:"document.server", defaultValue:"Server: \(review.resolution.endpoint)")))
            .textSelection(.enabled)
          Text(listening ? String(localized:"document.file.settings.override.saved.defaults.and.command.line.settings.for.every.accepted", defaultValue:"File settings override saved defaults and command-line settings for every accepted incoming connection. Start Listening binds this port; port 0 chooses an available port. Saved preferences are unchanged.") :
            String(localized:"document.file.settings.override.saved.defaults.for.this.new.connection.opening.does.not", defaultValue:"File settings override saved defaults for this new connection. Opening does not connect or change saved preferences."))
          if !review.resolution.notices.isEmpty {
            Text(String(localized:"document.these.fields.will.be.ignored", defaultValue:"These fields will be ignored:")).font(.headline)
            VStack(alignment:.leading,spacing:6) {
              ForEach(review.resolution.notices,id:\.line) { notice in
                Text(notice.kind == .platformOnly ? String(localized:"document.notice.platform", defaultValue:"Line \(notice.line.formatted()): \(notice.name) — Unavailable on macOS") : String(localized:"document.notice.unknown", defaultValue:"Line \(notice.line.formatted()): \(notice.name) — Unknown field"))
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
          }
          let numbers = review.resolution.monitorNumbers
          if !numbers.isEmpty {
            Text(String(localized:"document.displays.for.this.connection", defaultValue:"Displays for this connection")).font(.headline)
            VStack(alignment:.leading,spacing:6) {
              ForEach(numbers,id:\.self) { number in
                let id = review.resolution.resolvedMonitorMapping[number]
                let name = id.flatMap { displays.snapshot.display($0)?.name } ?? String(localized:"document.unavailable.display", defaultValue:"Unavailable display")
                Text(review.resolution.monitorSource == .commandLine ? String(localized:"document.monitor.commandline.assignment", defaultValue:"Command-line monitor \(number.formatted()): \(name)") : String(localized:"document.monitor.file.assignment", defaultValue:"File monitor \(number.formatted()): \(name)"))
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Text(review.monitorMapping == nil ? String(localized:"document.these.assignments.follow.the.current.display.arrangement.left.to.right.and.then", defaultValue:"These assignments follow the current display arrangement, left to right and then top to bottom. Change them if this file came from another arrangement.") : String(localized:"document.these.are.the.display.assignments.you.chose.for.this.connection", defaultValue:"These are the display assignments you chose for this connection."))
              .font(.caption).foregroundStyle(.secondary)
            Button(String(localized:"document.change.display.assignments", defaultValue:"Change Display Assignments…"),action:editMapping).accessibilityIdentifier("document.mapping.edit")
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
      ViewThatFits(in:.horizontal) {
        HStack { cancelAction; Spacer(); acceptAction }
        VStack(alignment:.leading,spacing:12) { cancelAction; acceptAction }
      }
    }.frame(maxWidth:620)
  }
  private var cancelAction: some View {
    Button(String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel,action:cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("document.cancel")
  }
  private var acceptAction: some View {
    Button(listening ? (review.resolution.notices.isEmpty ? String(localized:"listener.start.listening", defaultValue:"Start Listening") : String(localized:"document.ignore.listed.fields.and.listen", defaultValue:"Ignore Listed Fields and Listen")) :
      (review.resolution.notices.isEmpty ? String(localized:"profiles.open.connection", defaultValue:"Open Connection") : String(localized:"document.ignore.listed.fields.and.open", defaultValue:"Ignore Listed Fields and Open")),action:accept)
      .keyboardShortcut(.defaultAction).accessibilityIdentifier("document.accept")
  }
}
