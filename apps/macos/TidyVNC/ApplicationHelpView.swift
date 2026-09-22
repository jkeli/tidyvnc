// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import SwiftUI

// Keep the macOS 14 property wrapper explicit with newer SDKs that also
// provide a State macro, as in AuthenticationSheet.
private typealias HelpFieldState<Value> = SwiftUI.State<Value>

struct ApplicationHelpView: View {
  private enum Page: CaseIterable, Identifiable {
    case guide, acknowledgements, licence
    var title: String {
      switch self {
      case .guide: return String(localized:"help.topic.guide", defaultValue:"Getting Started")
      case .acknowledgements: return String(localized:"help.topic.acknowledgements", defaultValue:"Acknowledgements")
      case .licence: return String(localized:"help.topic.licence", defaultValue:"Licence")
      }
    }
    var id: Self { self }
  }
  @HelpFieldState<Page> private var page = .guide
  @HelpFieldState<String> private var document = ""
  @HelpFieldState<Bool> private var loading = false
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"help.title", defaultValue:"TidyVNC Help")).font(.title)
        .fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
      ViewThatFits(in:.horizontal) {
        topicPicker.pickerStyle(.segmented).fixedSize(horizontal:true,vertical:false)
        topicPicker.pickerStyle(.menu)
      }
      ScrollView {
        if page == .guide { guide }
        else if loading { ProgressView(String(localized:"help.loading", defaultValue:"Loading bundled document…")) }
        else {
          VStack(alignment:.leading,spacing:12) {
            if page == .acknowledgements {
              Text(String(localized:"help.acknowledgements.note", defaultValue:"The project README preserves upstream copyrights and acknowledgements and also describes the retained frontends."))
                .foregroundStyle(.secondary)
            }
            Text(verbatim:document).font(.system(.body,design:.monospaced))
              .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
              .accessibilityIdentifier("help.document")
          }.padding(4)
        }
      }.frame(maxWidth:.infinity,maxHeight:.infinity)
      HStack {
        Link(String(localized:"help.project", defaultValue:"Project and Source Code"),destination:URL(string:"https://github.com/jkeli/tidyvnc")!)
        Spacer()
        Link(String(localized:"help.issue", defaultValue:"Report an Issue"),destination:URL(string:"https://github.com/jkeli/tidyvnc/issues")!)
      }
      Text(String(localized:"help.privacy", defaultValue:"Before posting an issue, remove server addresses, usernames, credentials and other private information from screenshots or diagnostics."))
        .font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(minWidth:560,minHeight:440)
      .task(id:page) { await loadDocument() }
  }
  private var topicPicker: some View {
    Picker(String(localized:"help.topic.label", defaultValue:"Help topic"),selection:$page) {
      ForEach(Page.allCases) { Text($0.title).tag($0) }
    }.accessibilityIdentifier("help.topic")
  }
  private var guide: some View {
    VStack(alignment:.leading,spacing:16) {
      section(String(localized:"help.guide.connect.title", defaultValue:"Connect to a desktop"), String(localized:"help.guide.connect.body", defaultValue:"Enter a server address, then select Connect. Use host:display (for example, localhost:1), host::port (localhost::5901), or [IPv6]:display. A Unix socket path is also accepted. Obtain the address and credentials from the server administrator."))
      section(String(localized:"help.guide.ssh.title", defaultValue:"SSH gateways"), String(localized:"help.guide.ssh.body", defaultValue:"Leave SSH gateway empty for a direct connection. For a tunnel, enter user@host or ssh://user@host:port. An omitted user or port may come from supported ~/.ssh/config settings. Commands and proxy hops are unavailable. SSH forwarding requires a TCP server address and cannot be combined with listening for incoming connections."))
      section(String(localized:"help.guide.identity.title", defaultValue:"Verify server identity"), String(localized:"help.guide.identity.body", defaultValue:"Compare a new server or gateway fingerprint with the administrator before approving it. SSH gateway verification and the VNC server’s identity are separate decisions. Changed SSH gateway keys are rejected. SSH passwords and passphrases are used once; a failed gateway-key save prevents the VNC connection from starting."))
      section(String(localized:"help.guide.profiles.title", defaultValue:"Profiles, files and defaults"), String(localized:"help.guide.profiles.body", defaultValue:"Saved Profiles stores named addresses and connection settings. Open Connection creates a window; select Connect when ready. Settings supplies defaults for new windows, while connection settings apply to that window. Connection files are reviewed before use. Passwords are not exported with profiles or files."))
      section(String(localized:"help.guide.input.title", defaultValue:"Control and clipboard"), String(localized:"help.guide.input.body", defaultValue:"Click the remote desktop to direct keyboard and pointer input to it. View-only mode blocks remote input. The clipboard menu has independent Send and Receive controls. Input, Scaling and Encoding controls are available for a connected desktop; the Connection menu provides additional settings and desktop commands."))
      section(String(localized:"help.guide.listen.title", defaultValue:"Incoming connections"), String(localized:"help.guide.listen.body", defaultValue:"File → Listen for Connections opens a listener. Give the server this Mac’s network address and the displayed listening port, then accept or reject the incoming request. Closing the listener stops waiting for new connections."))
      section(String(localized:"help.guide.failure.title", defaultValue:"When a connection fails"), String(localized:"help.guide.failure.body", defaultValue:"Check the address, gateway, server availability and authentication details. A connection error does not prove that macOS denied Local Network access. Retry is explicit. Use Disconnect or Cancel to stop the current attempt; quitting the app closes its connections."))
    }.frame(maxWidth:.infinity,alignment:.leading).padding(4)
  }
  private func section(_ title: String, _ text: String) -> some View {
    VStack(alignment:.leading,spacing:5) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      Text(text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
    }
  }
  @MainActor private func loadDocument() async {
    document = ""; loading = page != .guide
    guard page != .guide else { return }
    let url = page == .licence ? Bundle.main.url(forResource:"LICENCE",withExtension:"TXT") : Bundle.main.url(forResource:"README",withExtension:"rst")
    let work = Task.detached(priority:.utility) { () -> String? in
      guard let url, !Task.isCancelled,
            let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
            size <= 1_048_576, let data = try? Data(contentsOf:url), data.count <= 1_048_576,
            !Task.isCancelled else { return nil }
      return String(data:data,encoding:.utf8)
    }
    let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    guard !Task.isCancelled else { return }
    document = result ?? String(localized:"help.document.unavailable", defaultValue:"The bundled document could not be read. See Project and Source Code for the original licence and acknowledgements.")
    loading = false
  }
}
