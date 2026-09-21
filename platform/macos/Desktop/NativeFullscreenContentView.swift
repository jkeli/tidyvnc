// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI

private struct StatisticsContent: View {
  let information: NativeConnectionInformation
  let width: CGFloat
  var body: some View {
    NativeConnectionStatisticsOverlay(information:information)
      .frame(width:width,alignment:.trailing).fixedSize(horizontal:false,vertical:true)
  }
}
// AppKit must also pass through hits: SwiftUI's allowsHitTesting alone does not
// guarantee that its hosting view won't intercept the desktop's mouse events.
@MainActor private final class StatisticsHost: NSHostingView<StatisticsContent> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
}

// The overlay is a sibling of the accessible remote image, so its combined
// statistics label is not hidden inside an accessibility leaf. No session,
// subscriptions, timers or rendering leases are owned by this container.
@MainActor final class NativeFullscreenContentView: NSView {
  let desktop: NativeDesktopView
  private var statistics: StatisticsHost?
  private(set) var statisticsInformation: NativeConnectionInformation?
  private var statisticsWidth: CGFloat = 0
  var statisticsView: NSView? { statistics }
  override var isFlipped: Bool { true }
  init(desktop: NativeDesktopView) {
    self.desktop = desktop
    super.init(frame:desktop.frame)
    clipsToBounds = true; setAccessibilityElement(false)
    desktop.frame = bounds; desktop.autoresizingMask = [.width,.height]
    addSubview(desktop)
  }
  required init?(coder: NSCoder) { nil }
  func showStatistics(_ information: NativeConnectionInformation?) {
    guard statisticsInformation != information else { return }
    statisticsInformation = information
    guard let information else {
      statistics?.removeFromSuperview(); statistics = nil; statisticsWidth = 0
      return
    }
    let width = max(0,min(360,bounds.width-24))
    let value = StatisticsContent(information:information,width:width)
    if let statistics { statistics.rootView = value }
    else {
      let host = StatisticsHost(rootView:value)
      host.setAccessibilityIdentifier("fullscreen.statistics")
      statistics = host; addSubview(host)
    }
    statisticsWidth = width; needsLayout = true
  }
  override func layout() {
    super.layout()
    guard let statistics, let information = statisticsInformation else { return }
    let width = max(0,min(360,bounds.width-24))
    if statisticsWidth != width {
      statisticsWidth = width; statistics.rootView = StatisticsContent(information:information,width:width)
    }
    let height = min(max(0,bounds.height-24),statistics.fittingSize.height)
    statistics.frame = .init(x:max(0,bounds.width-width-12),y:min(12,bounds.height),width:width,height:height)
  }
}
