// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import NativeKeyMap
import SwiftUI

public enum NativeCursorFallback: String, Codable, Hashable, CaseIterable, Sendable { case hidden, dot, system }

@MainActor
// AppKit invokes text-input clients on its main thread. The Objective-C protocol
// lacks actor annotations; defer conformance checking without moving UI state
// or text callbacks off MainActor.
public final class NativeDesktopView: NSView, @preconcurrency NSTextInputClient {
  private let resizeOwner = UUID()
  let focusOwner = UUID()
  private weak var resizeCoordinator: NativeRemoteResizeCoordinator?
  private var resizeTransition = false
  var resizeTransitionTimeout: Duration = .seconds(15)
  private var resizeTransitionRecovery: Task<Void,Never>?
  private weak var session: NativeSession?
  private var subscriptions = Set<AnyCancellable>()
  private weak var displays: NativeDisplayService?
  private var displaySubscription: AnyCancellable?
  public private(set) var displayGeneration: UInt64 = 0
  private weak var commandState: NativeDesktopCommands?
  private weak var fullscreenState: NativeFullscreenState?
  private weak var inputState: NativeInputState?
  private var inputSubscription: AnyCancellable?
  private weak var scalingState: NativeScalingState?
  weak var canvasCoordinator: NativeDesktopCanvas?
  var canvasOwnerID: UUID?
  var fullscreenOwnerID: UUID? { didSet { updateAutomaticResize() } }
  var fullscreenStateOwnerID: UUID?
  var onFullscreenPointerEntered: (() -> Void)? { didSet { updateTrackingAreas() } }
  func isBound(to session: NativeSession) -> Bool { self.session === session }
  private var scalingSubscription: AnyCancellable?
  private var changingScaling = false
  private var reportedScalingFailure = false
  private var geometry: NativeGeometry?
  private var desiredGeometry: NativeGeometry?
  public private(set) var canvasViewport: NativeCanvasViewport?
  private var availablePan: [NativeDesktopPan] = []
  private var desiredRequest: NativeTileRequest?
  private var sourceImage: NativeImage?
  private var displayedSource: NativeImage?
  private var tiles: [NativeRenderedTile] = []
  private weak var presentationPool: NativePresentationPool?
  private var presentationID: UUID?
  private var scheduler: NativeTileScheduler?
  private var renderingScaled = false
  private var presentedFilter: NativeScalingFilter = .nearest
  private var reportedRenderingFailure = false
  var rendererOverride: (any NativeTileRendering)? // Injection for deterministic presentation/lifetime tests.
  var cursorRendererOverride: (any NativeCursorRendering)?
  private var cursorScheduler: NativeCursorScheduler?
  private var cursorRequest: NativeCursorRequest?
  private(set) var cursorBatch: NativeCursorBatch?
  private var cursorPoint: CGPoint?
  private var reportedCursorFailure = false
  var displayedCursor: NSCursor? { remoteCursor }
  public var isRenderingCursor: Bool { cursorScheduler?.isRunning == true }
  public var cursorFallback: NativeCursorFallback = .hidden { didSet { updateCursor() } }
  public private(set) var displayedSequence: UInt64 = 0
  public private(set) var presentationBytes = 0
  public private(set) var renderedBytes = 0
  public private(set) var reusedTiles = 0
  public private(set) var usesDirectImage = false
  public private(set) var lastInvalidatedRectangle = CGRect.zero
  public var isRendering: Bool { scheduler?.isRunning == true }
  private var imageSize: CGSize = .zero
  private var cursorImage: NativeImage?
  private var remoteCursor: NSCursor?
  private var tracking: NSTrackingArea?
  private var shortcutRouter: NativeShortcutRouter?
  private var shortcutModifiers: NativeShortcutModifiers = .builtIn
  private var fullscreenSystemKeys = true
  private var capture: any NativeKeyboardCapturing = NativeKeyboardCapture()
  private var captureWasActive = false
  private var captureSuppressed = false
  private var automaticCaptureAttempted = false
  // Tests inject a backend and eligibility without capturing the user's keyboard.
  var captureOverride: (any NativeKeyboardCapturing)? { didSet { capture.stop(); capture = captureOverride ?? NativeKeyboardCapture() } }
  var captureEligibilityOverride: (() -> Bool)?
  var fullscreenOverride: (() -> Bool)?
  public var onContextMenu: ((NSView) -> Void)?
  private var held: [UInt16: UInt32] = [:]
  private var buttons: UInt32 = 0
  private var wheelX = 0.0, wheelY = 0.0
  private var marked = NSAttributedString(string: "")
  private var selection = NSRange(location: 0, length: 0)
  private var interpreting: NSEvent?
  private var wasComposing = false
  private var capsLock = false
  private var lastState: NativeSessionState = .idle
  private var lastPointer = CGPoint.zero
  public private(set) var displayedImage: CGImage?
  public var onError: ((String) -> Void)?
  public var scaling = "FixedRatio" { didSet {
    guard !changingScaling else { return }
    if canvasCoordinator != nil {
      changingScaling = true; scaling = oldValue; changingScaling = false; reportManagedScaling()
    } else { updateGeometry() }
  } }
  public var devicePixels = false { didSet {
    guard !changingScaling else { return }
    if canvasCoordinator != nil {
      changingScaling = true; devicePixels = oldValue; changingScaling = false; reportManagedScaling()
    } else { updateGeometry() }
  } }
  public var filter: NativeScalingFilter = .bilinear { didSet {
    guard !changingScaling else { return }
    if canvasCoordinator != nil {
      changingScaling = true; filter = oldValue; changingScaling = false; reportManagedScaling()
    } else { updateGeometry() }
  } }
  private func reportManagedScaling() { onError?(String(localized:"desktop.change.scaling.settings.for.the.shared.desktop.canvas", defaultValue:"Change Scaling Settings for the shared desktop canvas.")) }
  public var pan = CGPoint.zero { didSet {
    guard !changingScaling else { return }
    if let canvasCoordinator {
      let candidate = pan
      changingScaling = true; pan = oldValue; changingScaling = false
      do { try canvasCoordinator.setPan(candidate) } catch { onError?(NativePresentationIssue(error:error,context:.layout).message) }
    } else { updateGeometry() }
  } }
  public var desktopRectangle: CGRect { geometry?.rectangle ?? .zero }
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }
  public override var isOpaque: Bool { true }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
    NotificationCenter.default.addObserver(self, selector: #selector(updateFocus), name: NSApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(updateFocus), name: NSApplication.didResignActiveNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspendInput), name: NSWorkspace.willSleepNotification, object: nil)
    setAccessibilityElement(true); setAccessibilityRole(.image)
    setAccessibilityLabel(String(localized:"ssh.remote.desktop", defaultValue:"Remote desktop"))
    setAccessibilityHelp(String(localized:"desktop.click.to.focus.keyboard.and.pointer.input.control.the.connected.computer", defaultValue:"Click to focus. Keyboard and pointer input control the connected computer."))
    setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized:"desktop.focus.remote.desktop", defaultValue:"Focus remote desktop"), target: self, selector: #selector(focusDesktop))])
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  deinit {
    resizeTransitionRecovery?.cancel()
    let resizeCoordinator = resizeCoordinator, resizeOwner = resizeOwner
    let focusSession = session, focusOwner = focusOwner
    let pool = presentationPool, id = presentationID
    Task { @MainActor [weak focusSession] in
      try? focusSession?.setDesktopFocused(false,owner:focusOwner)
      resizeCoordinator?.detach(owner:resizeOwner)
      if let id { pool?.release(id) }
    }
  }
  public func bind(_ session: NativeSession) {
    guard self.session !== session else { return }
    detach(); self.session = session
    shortcutModifiers = session.initialInput.shortcutModifiers
    fullscreenSystemKeys = session.initialInput.fullscreenSystemKeys
    cursorFallback = session.initialInput.cursorFallback
    if let value = session.initialScaling {
      changingScaling = true; scaling = value.canonical; devicePixels = value.devicePixels; filter = value.filter; pan = .zero; changingScaling = false
    }
    do {
      shortcutRouter = try NativeShortcutRouter(modifiers: shortcutModifiers)
      let (id, renderer) = try session.presentations.acquire(renderer: rendererOverride, cursorRenderer: cursorRendererOverride)
      presentationPool = session.presentations; presentationID = id; scheduler = renderer
      cursorScheduler = session.presentations.cursor(id)
      cursorScheduler?.onFrame = { [weak self] batch in
        guard let self, self.presentationID == id, self.session?.isClosing == false,
              let desired = self.cursorRequest, batch.request.hasSamePresentation(as: desired),
              batch.native || batch.blank || desired.point != nil else { return }
        self.installCursor(batch)
      }
      cursorScheduler?.onError = { [weak self] error in
        guard let self, self.presentationID == id, self.session?.isClosing == false else { return }
        self.invalidateCursorPresentation(); self.remoteCursor = .arrow
        self.window?.invalidateCursorRects(for: self)
        if !self.reportedCursorFailure { self.reportedCursorFailure = true; self.onError?(NativePresentationIssue(error:error,context:.cursor).message) }
      }
      renderer.onFrame = { [weak self] batch in
        guard let self, self.presentationID == id, self.session?.isClosing == false,
              let desired = self.desiredRequest, batch.request.hasSamePresentation(as: desired),
              let geometry = self.desiredGeometry else { return }
        self.present(batch.request.image, geometry: geometry, tiles: batch.tiles, filter: batch.request.filter,
          bytes: batch.bytes, rendered: batch.renderedBytes, reused: batch.reusedTiles)
      }
      renderer.onError = { [weak self] error in
        guard let self, self.presentationID == id, self.session?.isClosing == false else { return }
        self.renderingFailed(error)
      }
    } catch { self.session = nil; onError?(NativePresentationIssue(error:error,context:.desktop).message); return }
    resizeCoordinator = session.remoteResize
    if window != nil && canvasViewport == nil { resizeCoordinator?.attach(owner:resizeOwner) }
    session.frameUpdates.sink { [weak self] value in MainActor.assumeIsolated { self?.install(value) } }.store(in: &subscriptions)
    session.cursorUpdates.sink { [weak self] value in MainActor.assumeIsolated {
      self?.cursorImage = value; self?.updateCursor()
    } }.store(in: &subscriptions)
    session.$desktopFocusOwner.removeDuplicates().sink { [weak self] owner in MainActor.assumeIsolated {
      guard let self, owner != self.focusOwner else { return }
      self.clearInput(); self.captureSuppressed = false; self.automaticCaptureAttempted = false
    }}.store(in:&subscriptions)
    session.$isFocused.removeDuplicates().sink { [weak self] value in MainActor.assumeIsolated {
      if !value {
        self?.clearInput(); self?.captureSuppressed = false; self?.automaticCaptureAttempted = false
      }
    } }.store(in: &subscriptions)
    session.$isViewOnly.removeDuplicates().sink { [weak self] value in MainActor.assumeIsolated {
      if value { self?.clearInput() }
      self?.updateCursor(viewOnly: value)
    } }.store(in: &subscriptions)
    session.$emulatesMiddleButton.removeDuplicates().sink { [weak self] _ in MainActor.assumeIsolated {
      self?.clearInput()
    } }.store(in: &subscriptions)
    session.$isClosing.removeDuplicates().sink { [weak self] value in MainActor.assumeIsolated {
      if value { self?.setFocus(false); self?.updatePanActions(closing: true) }
    } }.store(in: &subscriptions)
    session.$snapshot.sink { [weak self, weak session] value in MainActor.assumeIsolated {
      guard let self else { return }
      let previous = self.lastState; self.lastState = value.state
      self.updatePanActions()
      if value.state == .connected && previous != .connected {
        Task { @MainActor [weak self, weak session] in
          guard let self, let session, self.session === session, session.generation == value.generation,
                !session.isClosing else { return }
          if self.window?.isKeyWindow == true { self.window?.makeFirstResponder(self) }
          self.updateFocus()
        }
      } else if value.state != .connected { self.clearInput() }
    } }.store(in: &subscriptions)
  }
  public func detach() {
    fullscreenState?.detach(self); fullscreenState = nil
    canvasCoordinator?.remove(self)
    session?.remoteResize.detach(owner:resizeOwner); resizeCoordinator = nil; resizeTransitionRecovery?.cancel(); resizeTransitionRecovery = nil; resizeTransition = false
    setFocus(false); commandState?.detach(self); commandState = nil
    subscriptions.removeAll(); session = nil
    if let id = presentationID { presentationPool?.release(id) }
    presentationID = nil; presentationPool = nil; scheduler = nil; cursorScheduler = nil; renderingScaled = false
    cursorRequest = nil; cursorPoint = nil; reportedCursorFailure = false
    desiredGeometry = nil; desiredRequest = nil; sourceImage = nil; reportedRenderingFailure = false
    changingScaling = true; pan = .zero; changingScaling = false; updatePanActions()
    scalingState?.unregister(self)
    inputSubscription = nil; inputState = nil
    scalingSubscription = nil; scalingState = nil; reportedScalingFailure = false
    displaySubscription = nil; displays = nil; displayGeneration = 0
    imageSize = .zero; cursorImage = nil; clearPresentation()
    needsDisplay = true; window?.invalidateCursorRects(for: self)
  }
  public func observeCommands(_ state: NativeDesktopCommands?) {
    guard commandState !== state else { return }
    commandState?.detach(self); commandState = state; state?.register(self)
    if session?.desktopFocusOwner == focusOwner { state?.attach(self) }
  }
  public func observeFullscreen(_ state: NativeFullscreenState?) {
    if fullscreenState !== state { fullscreenState?.detach(self); fullscreenState = state }
    state?.attach(self)
  }
  public func observeInput(_ state: NativeInputState?) {
    guard inputState !== state else { return }
    inputSubscription = nil; inputState = state
    inputSubscription = state?.$value.sink { [weak self] value in MainActor.assumeIsolated {
      guard let self else { return }
      if self.shortcutModifiers != value.shortcutModifiers {
        _ = self.send { try $0.releaseInput() }
        self.commandState?.inputReleasedForShortcut(from:self); self.clearInput()
        do { try self.shortcutRouter?.setModifiers(value.shortcutModifiers); self.shortcutModifiers = value.shortcutModifiers }
        catch { self.onError?(NativePresentationIssue(error:error,context:.shortcut).message) }
      }
      if self.fullscreenSystemKeys != value.fullscreenSystemKeys {
        self.fullscreenSystemKeys = value.fullscreenSystemKeys
        self.automaticCaptureAttempted = false
        if !value.fullscreenSystemKeys { self.releaseKeyboardForCommand() }
        else { self.captureSuppressed = false }
      }
      self.cursorFallback = value.cursorFallback
      self.updateKeyboardCapture()
    } }
  }
  public func observeScaling(_ state: NativeScalingState?) {
    guard scalingState !== state else { return }
    if let canvasCoordinator, !canvasCoordinator.usesScaling(state) { canvasCoordinator.remove(self) }
    scalingState?.unregister(self)
    scalingSubscription = nil; scalingState = state; state?.register(self)
    scalingSubscription = state?.$value.sink { [weak self] value in MainActor.assumeIsolated {
      guard let self, self.canvasCoordinator == nil else { return }
      self.changingScaling = true
      if self.scaling != value.canonical || self.devicePixels != value.devicePixels { self.pan = .zero }
      self.scaling = value.canonical; self.devicePixels = value.devicePixels; self.filter = value.filter
      self.changingScaling = false; self.updateGeometry()
    } }
  }
  func validateScaling(_ value: NativeScaling) throws {
    // The hidden windowed host is not part of the fullscreen canvas. Its current
    // backing limits must not reject a scale valid for all active surfaces.
    if fullscreenOwnerID != nil && isHidden { return }
    if let canvasCoordinator { try canvasCoordinator.validateScaling(value); return }
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
    let geometry = try makeGeometry(scaling: value.canonical, devicePixels: value.devicePixels, pan: .zero)
    if let sourceImage, !geometry.isIdentity { _ = try NativeTileGrid(tileRequest(sourceImage, geometry: geometry)) }
  }
  private func makeGeometry(scaling: String, devicePixels: Bool, pan: CGPoint) throws -> NativeGeometry {
    try NativeGeometry(width: UInt32(imageSize.width), height: UInt32(imageSize.height),
      viewport: bounds.size, backingScale: Double(window?.backingScaleFactor ?? 1),
      scaling: scaling, devicePixels: devicePixels, pan: pan, canvas: canvasViewport)
  }
  // The fullscreen owner supplies a coherent canvas and shared pan to each
  // surface. Check allocations before changing the displayed view's intent.
  public func setCanvasViewport(_ value: NativeCanvasViewport?, pan newPan: CGPoint = .zero) throws {
    guard canvasCoordinator == nil else { throw NativeError(.busy,"Canvas is managed by its surface coordinator") }
    try validateCanvas(value,pan:newPan,scaling:NativeScaling(scaling,devicePixels:devicePixels,filter:filter))
    installCanvas(value,pan:newPan)
  }
  func validateCanvas(_ value: NativeCanvasViewport?, pan newPan: CGPoint, scaling candidate: NativeScaling) throws {
    guard newPan.x.isFinite, newPan.y.isFinite, newPan.x >= 0, newPan.y >= 0,
          newPan.x <= 65535, newPan.y <= 65535 else { throw NativeError(.invalidArgument,"Invalid canvas pan") }
    if sourceImage != nil, imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 {
      let geometry = try NativeGeometry(width:UInt32(imageSize.width),height:UInt32(imageSize.height),
        viewport:bounds.size,backingScale:Double(window?.backingScaleFactor ?? 1),
        scaling:candidate.canonical,devicePixels:candidate.devicePixels,pan:newPan,canvas:value)
      if let sourceImage, !geometry.isIdentity { _ = try NativeTileGrid(tileRequest(sourceImage,geometry:geometry)) }
    }
  }
  // All members are preflighted before any synchronous presentation intent changes.
  func installCanvas(_ value: NativeCanvasViewport?, pan newPan: CGPoint, scaling candidate: NativeScaling? = nil) {
    guard canvasViewport != value || pan != newPan || candidate != nil else { return }
    let wasCanvas = canvasViewport != nil
    changingScaling = true; canvasViewport = value; pan = newPan
    if let candidate { scaling = candidate.canonical; devicePixels = candidate.devicePixels; filter = candidate.filter }
    changingScaling = false
    if value != nil { resizeCoordinator?.detach(owner:resizeOwner) }
    else if wasCanvas, window != nil { resizeCoordinator?.attach(owner:resizeOwner) }
    updateGeometry()
  }
  func leaveCanvas(owner: UUID) {
    guard canvasOwnerID == owner else { return }
    canvasOwnerID = nil; canvasCoordinator = nil
    installCanvas(nil,pan:.zero,scaling:scalingState?.value)
  }
  func setSharedPan(_ point: CGPoint) {
    guard pan != point else { return }
    changingScaling = true; pan = point; changingScaling = false; updateGeometry()
  }
  public func observeDisplays(_ service: NativeDisplayService?) {
    guard displays !== service else { return }
    displaySubscription = nil; displays = service; displayGeneration = 0
    displaySubscription = service?.$snapshot.sink { [weak self] value in MainActor.assumeIsolated {
      self?.displayGeneration = value.generation; self?.updateGeometry()
    } }
  }
  private func install(_ image: NativeImage?) {
    if image == nil || sourceImage?.streamID != image?.streamID || sourceImage?.generation != image?.generation {
      changingScaling = true; pan = canvasCoordinator?.pan ?? .zero; changingScaling = false
    }
    if let shown = displayedSource, let image,
       shown.streamID != image.streamID || shown.generation != image.generation || shown.sizeGeneration != image.sizeGeneration {
      clearPresentation() // A resized/replaced desktop cannot use the old input map.
    }
    sourceImage = image
    imageSize = image.map { CGSize(width: Int($0.width), height: Int($0.height)) } ?? .zero
    updateGeometry()
  }
  private func clearPresentation() {
    setFocus(false)
    cursorPoint = nil
    clearCursor()
    displayedImage = nil; displayedSource = nil; tiles = []; geometry = nil; remoteCursor = nil
    displayedSequence = 0; presentationBytes = 0; renderedBytes = 0; reusedTiles = 0; usesDirectImage = false
    needsDisplay = true; window?.invalidateCursorRects(for: self)
    updatePanActions()
  }
  private func resetRendering() {
    desiredRequest = nil
    if renderingScaled { scheduler?.reset(); renderingScaled = false }
  }
  private func tileRequest(_ image: NativeImage, geometry: NativeGeometry) -> NativeTileRequest {
    let visible = geometry.rectangle.intersection(bounds)
    let q = geometry.backingScale
    let left = max(0, min(Double(geometry.backingWidth), floor((visible.minX-geometry.rectangle.minX)*q)))
    let top = max(0, min(Double(geometry.backingHeight), floor((visible.minY-geometry.rectangle.minY)*q)))
    let right = max(left, min(Double(geometry.backingWidth), ceil((visible.maxX-geometry.rectangle.minX)*q)))
    let bottom = max(top, min(Double(geometry.backingHeight), ceil((visible.maxY-geometry.rectangle.minY)*q)))
    let region = visible.isNull || visible.isEmpty ? NativePixelRect(x: 0, y: 0, width: 0, height: 0) :
      NativePixelRect(x: UInt32(left), y: UInt32(top), width: UInt32(right-left), height: UInt32(bottom-top))
    return NativeTileRequest(image: image, width: geometry.backingWidth, height: geometry.backingHeight, visible: region, filter: filter)
  }
  func restoreAutomaticResize() {
    guard fullscreenOwnerID == nil, canvasViewport == nil, window != nil else { return }
    resizeCoordinator?.attach(owner:resizeOwner); updateAutomaticResize()
  }
  private func updateAutomaticResize() {
    session?.remoteResize.update(owner:resizeOwner,viewport:NativeResizeViewport(
      width:bounds.width,height:bounds.height,scale:Double(window?.backingScaleFactor ?? 1),
      unscaled:(try? NativeScaling(scaling).mode) == .unscaled,devicePixels:devicePixels,
      available:commandState?.isMinimizing != true && fullscreenOwnerID == nil && canvasViewport == nil && window != nil && !isHiddenOrHasHiddenAncestor && window?.isMiniaturized == false && !resizeTransition))
  }
  @objc private func resizeFullscreenWillChange(_ notification: Notification) {
    resizeTransition = true; updateAutomaticResize(); resizeTransitionRecovery?.cancel()
    let timeout = resizeTransitionTimeout
    resizeTransitionRecovery = Task { @MainActor [weak self] in
      do { try await Task.sleep(for:timeout) } catch { return }
      guard let self else { return }; self.resizeTransition = false; self.resizeTransitionRecovery = nil; self.updateAutomaticResize()
    }
  }
  private func updateGeometry() {
    updateAutomaticResize()
    guard let sourceImage, imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0,
          !isHiddenOrHasHiddenAncestor, session?.isClosing == false else {
      desiredGeometry = nil; resetRendering(); clearPresentation(); return
    }
    let next: NativeGeometry
    do {
      next = try makeGeometry(scaling: scaling, devicePixels: devicePixels, pan: pan)
      reportedScalingFailure = false
    } catch {
      guard let fit = try? makeGeometry(scaling: "FixedRatio", devicePixels: false, pan: .zero) else {
        desiredGeometry = nil; resetRendering(); clearPresentation(); renderingFailed(error); return
      }
      next = fit
      if !reportedScalingFailure {
        reportedScalingFailure = true
        onError?(String(localized:"desktop.the.selected.scaling.exceeds.the.display.limits.the.desktop.is.temporarily.fitted", defaultValue:"The selected scaling exceeds the display limits. The desktop is temporarily fitted to the window. Choose a smaller scale in Scaling Settings."))
      }
    }
    desiredGeometry = next
    // Discard excess offsets when the window or remote desktop grows/shrinks;
    // otherwise a later resize could unexpectedly restore a stale pan.
    changingScaling = true; pan = canvasCoordinator?.pan ?? next.panPosition; changingScaling = false
    updatePanActions()
    if next.isIdentity {
      resetRendering()
      present(sourceImage, geometry: next, tiles: [], filter: filter, bytes: 0, rendered: 0, reused: 0)
    } else {
      let request = tileRequest(sourceImage, geometry: next)
      do { _ = try NativeTileGrid(request) }
      catch { resetRendering(); renderingFailed(error); return }
      desiredRequest = request; renderingScaled = true; scheduler?.submit(request)
    }
  }
  private func present(_ image: NativeImage, geometry next: NativeGeometry, tiles: [NativeRenderedTile],
                       filter: NativeScalingFilter, bytes: Int, rendered: Int, reused: Int) {
    do {
      let nativeImage = try displayedSource === image ? displayedImage : image.makeCGImage()
      var dirty = bounds
      if let previous = displayedSource, let geometry,
         previous.streamID == image.streamID, previous.generation == image.generation, previous.sizeGeneration == image.sizeGeneration,
         geometry.rectangle == next.rectangle, geometry.backingScale == next.backingScale, presentedFilter == filter {
        if previous.sequence == image.sequence { dirty = .zero }
        else if previous.sequence == image.previousSequence {
          dirty = try next.damageRectangle(image.damage, filter: filter).intersection(bounds)
        }
      }
      displayedImage = nativeImage; displayedSource = image; geometry = next; self.tiles = tiles; presentedFilter = filter
      displayedSequence = image.sequence; presentationBytes = bytes; renderedBytes = rendered; reusedTiles = reused
      usesDirectImage = next.isIdentity; reportedRenderingFailure = false
      lastInvalidatedRectangle = dirty
      if !dirty.isNull && !dirty.isEmpty { setNeedsDisplay(dirty) }
      updateCursor(); updateFocus()
    } catch { scheduler?.reset(); renderingFailed(error) }
  }
  private func renderingFailed(_ error: any Error) {
    guard !reportedRenderingFailure else { return }
    reportedRenderingFailure = true; onError?(NativePresentationIssue(error:error,context:.desktop).message)
  }
  public override func layout() { super.layout(); updateGeometry() }
  public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
  public override func viewDidHide() { super.viewDidHide(); updateGeometry() }
  public override func viewDidUnhide() { super.viewDidUnhide(); updateGeometry() }
  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); defer { context.restoreGState() }
    context.clip(to: bounds)
    NSColor.black.setFill(); dirtyRect.intersection(bounds).fill()
    guard let image = displayedImage, let geometry else { return }
    context.interpolationQuality = .none
    func drawImage(_ image: CGImage, in rectangle: CGRect) {
      guard rectangle.intersects(dirtyRect) else { return }
      context.saveGState(); defer { context.restoreGState() }
      context.translateBy(x: rectangle.minX, y: rectangle.maxY); context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(origin: .zero, size: rectangle.size))
    }
    if usesDirectImage { drawImage(image, in: geometry.rectangle) }
    else {
      for tile in tiles {
        let q = geometry.backingScale
        drawImage(tile.image, in: CGRect(x: geometry.rectangle.minX + Double(tile.rect.x)/q,
          y: geometry.rectangle.minY + Double(tile.rect.y)/q, width: Double(tile.rect.width)/q, height: Double(tile.rect.height)/q))
      }
    }
    if let batch = cursorBatch, !batch.native, !batch.blank, !batch.tiles.isEmpty {
      context.saveGState(); defer { context.restoreGState() }
      context.clip(to: batch.request.clip)
      for tile in batch.tiles {
        let q = batch.request.backingScale
        drawImage(tile.image, in: CGRect(x: batch.origin.x+Double(tile.rect.x)/q,
          y: batch.origin.y+Double(tile.rect.y)/q, width: Double(tile.rect.width)/q, height: Double(tile.rect.height)/q))
      }
    }
  }
  private static let invisibleCursor: NSCursor = {
    let provider = CGDataProvider(data: Data([0,0,0,0]) as CFData)!
    let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return NSCursor(image: NSImage(cgImage: image, size: NSSize(width: 1, height: 1)), hotSpot: .zero)
  }()
  private static let dotCursor: NSCursor = {
    let image = NSImage(size: NSSize(width: 5, height: 5), flipped: false) { rect in
      NSColor.white.setFill(); NSBezierPath(ovalIn: rect).fill()
      NSColor.black.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 2, y: 2))
  }()
  private var fallbackCursor: NSCursor {
    switch cursorFallback { case .hidden: Self.invisibleCursor; case .dot: Self.dotCursor; case .system: .arrow }
  }
  private func invalidateCursorPresentation() {
    if let batch = cursorBatch, !batch.native {
      let dirty = batch.rectangle.intersection(batch.request.clip).intersection(bounds)
      if !dirty.isEmpty && !dirty.isNull { setNeedsDisplay(dirty) }
    }
    cursorBatch = nil; remoteCursor = nil
  }
  private func clearCursor() {
    if cursorRequest != nil { cursorScheduler?.reset() }
    cursorRequest = nil; invalidateCursorPresentation()
    window?.invalidateCursorRects(for: self)
  }
  private func installCursor(_ batch: NativeCursorBatch) {
    invalidateCursorPresentation(); cursorBatch = batch; reportedCursorFailure = false
    if batch.blank { remoteCursor = fallbackCursor }
    else if batch.native, let tile = batch.tiles.first {
      let q = batch.request.backingScale
      let image = NSImage(cgImage: tile.image, size: NSSize(width: Double(batch.width)/q, height: Double(batch.height)/q))
      remoteCursor = NSCursor(image: image, hotSpot: NSPoint(x: Double(batch.hotspotX)/q, y: Double(batch.hotspotY)/q))
    } else {
      remoteCursor = Self.invisibleCursor
      let dirty = batch.rectangle.intersection(batch.request.clip).intersection(bounds)
      if !batch.tiles.isEmpty && !dirty.isEmpty && !dirty.isNull { setNeedsDisplay(dirty) }
    }
    window?.invalidateCursorRects(for: self)
  }
  private func updateCursor(viewOnly: Bool? = nil) {
    guard let geometry, let displayedSource, !isHiddenOrHasHiddenAncestor, session?.isClosing == false,
          !(viewOnly ?? session?.isViewOnly ?? false) else { clearCursor(); remoteCursor = .arrow; return }
    guard let cursorImage, cursorImage.generation == displayedSource.generation else {
      clearCursor(); remoteCursor = fallbackCursor; window?.invalidateCursorRects(for: self); return
    }
    let clip = geometry.rectangle.intersection(bounds)
    guard !clip.isNull && !clip.isEmpty else { clearCursor(); return }
    let next = NativeCursorRequest(image: cursorImage, scaleX: Double(geometry.backingWidth)/Double(displayedSource.width),
      scaleY: Double(geometry.backingHeight)/Double(displayedSource.height), backingScale: geometry.backingScale,
      filter: presentedFilter, clip: clip, point: cursorPoint.flatMap { clip.contains($0) ? $0 : nil })
    if let cursorBatch, cursorBatch.request.hasSamePresentation(as: next), cursorBatch.native || cursorBatch.blank {
      if cursorBatch.blank { remoteCursor = fallbackCursor; window?.invalidateCursorRects(for: self) }
      return
    }
    if cursorRequest?.hasSamePresentation(as: next) != true { invalidateCursorPresentation() }
    if next.point == nil && cursorBatch?.native == false { invalidateCursorPresentation() }
    cursorRequest = next; cursorScheduler?.submit(next)
    window?.invalidateCursorRects(for: self)
  }
  public override func resetCursorRects() {
    super.resetCursorRects()
    if let geometry {
      let rectangle = geometry.rectangle.intersection(bounds)
      if !rectangle.isNull && !rectangle.isEmpty { addCursorRect(rectangle, cursor: remoteCursor ?? .arrow) }
    }
  }
  public override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let activity: NSTrackingArea.Options = onFullscreenPointerEntered == nil ? .activeInKeyWindow : .activeInActiveApp
    let value = NSTrackingArea(rect: .zero, options: [activity, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate], owner: self, userInfo: nil)
    addTrackingArea(value); tracking = value; super.updateTrackingAreas()
  }
  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let window {
      NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.willExitFullScreenNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: window)
      NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: window)
    }
    session?.remoteResize.detach(owner:resizeOwner); resizeTransitionRecovery?.cancel(); resizeTransitionRecovery = nil; resizeTransition = false
    setFocus(false); super.viewWillMove(toWindow: newWindow)
  }
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    fullscreenState?.attach(self)
    if let window {
      if canvasViewport == nil { resizeCoordinator?.attach(owner:resizeOwner) }
      window.acceptsMouseMovedEvents = true
      NotificationCenter.default.addObserver(self, selector: #selector(updateFocus), name: NSWindow.didBecomeKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(updateFocus), name: NSWindow.didResignKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(suspendInput), name: NSWindow.willCloseNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(resizeFullscreenWillChange), name: NSWindow.willEnterFullScreenNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(resizeFullscreenWillChange), name: NSWindow.willExitFullScreenNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(resizeWindowVisibilityChanged), name: NSWindow.didMiniaturizeNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(resizeWindowVisibilityChanged), name: NSWindow.didDeminiaturizeNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(fullscreenChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(fullscreenChanged), name: NSWindow.didExitFullScreenNotification, object: window)
    }
    updateFocus(); updateGeometry()
  }
  @objc public func focusDesktop() -> Bool {
    guard commandState?.isMinimizing != true, let window, window.makeFirstResponder(self) else { return false }
    // AppKit need not call becomeFirstResponder when this view is already the
    // responder. An explicit click/accessibility action still refreshes focus.
    updateFocus(); return true
  }
  private func updatePanActions(closing: Bool = false) {
    let enabled = closing ? [] : NativeDesktopPan.allCases.filter { canPan($0) }
    guard enabled != availablePan else { return }
    availablePan = enabled
    let selectors: [NativeDesktopPan: Selector] = [.left: #selector(panLeft), .right: #selector(panRight),
      .up: #selector(panUp), .down: #selector(panDown), .origin: #selector(panOrigin)]
    var actions = [NSAccessibilityCustomAction(name: String(localized:"desktop.focus.remote.desktop", defaultValue:"Focus remote desktop"), target: self, selector: #selector(focusDesktop))]
    actions += enabled.map { NSAccessibilityCustomAction(name: $0.title, target: self, selector: selectors[$0]!) }
    setAccessibilityCustomActions(actions)
    NSAccessibility.post(element: self, notification: .layoutChanged)
    commandState?.panAvailabilityChanged()
  }
  @objc private func panLeft() -> Bool { panDesktop(.left) }
  @objc private func panRight() -> Bool { panDesktop(.right) }
  @objc private func panUp() -> Bool { panDesktop(.up) }
  @objc private func panDown() -> Bool { panDesktop(.down) }
  @objc private func panOrigin() -> Bool { panDesktop(.origin) }
  @objc private func suspendInput() { setFocus(false) }
  @objc private func updateFocus() {
    setFocus(commandState?.isMinimizing != true && NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false && window?.firstResponder === self && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor)
    if !NSApp.isActive || window?.isKeyWindow != true { cursorPoint = nil; updateCursor() }
    else if cursorPoint == nil, let window {
      let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      cursorPoint = bounds.contains(point) ? point : nil; updateCursor()
    }
  }
  private var ownsInputRoute: Bool {
    guard fullscreenOwnerID == nil, let session else { return false }
    // Explicit unscoped session focus remains available to non-view consumers.
    return session.desktopFocusOwner == nil || session.desktopFocusOwner == focusOwner
  }
  @discardableResult func setFocus(_ focused: Bool) -> Bool {
    let focused = focused && fullscreenOwnerID == nil && commandState?.isMinimizing != true && window?.isMiniaturized != true
    if !focused { clearInput(); captureSuppressed = false; automaticCaptureAttempted = false }
    guard let session else { return false }
    do { try session.setDesktopFocused(focused,owner:focusOwner,releaseUnowned:true) }
    catch { if focused { clearInput() }; return false }
    if focused { commandState?.attach(self); updateKeyboardCapture() }
    return true
  }
  private func clearInput(resetShortcuts: Bool = true) {
    held.removeAll(); buttons = 0; wheelX = 0; wheelY = 0; unmarkText()
    if resetShortcuts { try? shortcutRouter?.reset(); capture.stop(); captureWasActive = false; commandState?.captureChanged(false,from:self) }
  }
  private var captureEligible: Bool {
    ownsInputRoute && commandState?.isMinimizing != true && window?.isMiniaturized != true && session?.isClosing == false && session?.snapshot.state == .connected && session?.isViewOnly == false && session?.isFocused == true &&
      (captureEligibilityOverride?() ?? (NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor))
  }
  private var fullscreen: Bool { fullscreenOverride?() ?? (window?.styleMask.contains(.fullScreen) == true) }
  @objc private func resizeWindowVisibilityChanged() { updateAutomaticResize() }
  @objc private func fullscreenChanged() {
    resizeTransitionRecovery?.cancel(); resizeTransitionRecovery = nil; resizeTransition = false; updateAutomaticResize()
    automaticCaptureAttempted = false
    if !fullscreen { releaseKeyboardForCommand(); captureSuppressed = false }
    updateKeyboardCapture()
  }
  func updateKeyboardCapture() {
    guard captureEligible else {
      if captureWasActive { _ = send { try $0.releaseInput() }; commandState?.inputReleasedForShortcut(from:self); clearInput(resetShortcuts: false) }
      capture.stop(); captureWasActive = false; commandState?.captureChanged(false,from:self); return
    }
    if captureWasActive && !capture.isActive {
      capture.stop(); captureWasActive = false; captureSuppressed = true
      _ = send { try $0.releaseInput() }; commandState?.inputReleasedForShortcut(from:self); clearInput()
      commandState?.captureChanged(false, message: String(localized:"desktop.keyboard.capture.ended.use.capture.keyboard.to.try.again", defaultValue:"Keyboard capture ended. Use Capture Keyboard to try again."),from:self)
    }
    if fullscreenSystemKeys && fullscreen && !captureSuppressed && !automaticCaptureAttempted && !capture.isActive {
      automaticCaptureAttempted = true
      do { try captureKeyboardForCommand() } catch { /* Status contains actionable recovery; avoid a focus-stealing alert. */ }
    }
  }
  private static func candidates(_ code: UInt16) -> [UInt32] {
    var values = [UInt32](repeating: 0, count: 37)
    let count = values.withUnsafeMutableBufferPointer { native_macos_shortcut_candidates(code, $0.baseAddress, UInt32($0.count)) }
    return Array(values.prefix(Int(count)))
  }
  // Returns true only when the event should continue through normal remote input.
  private func routeShortcut(_ event: NSEvent, down: Bool) -> Bool {
    guard ownsInputRoute, commandState?.isMinimizing != true, let shortcutRouter, session?.isClosing == false, session?.isFocused == true, session?.snapshot.state == .connected else { return false }
    updateKeyboardCapture()
    do {
      let special = native_macos_special_keysym(event.keyCode)
      let symbol = special != 0 ? special : event.charactersIgnoringModifiers?.unicodeScalars.first.map { native_unicode_keysym($0.value) } ?? 0
      let decision = try down ? shortcutRouter.press(id: Int32(event.keyCode), keysym: symbol, candidates: Self.candidates(event.keyCode)) : shortcutRouter.release(id: Int32(event.keyCode))
      if decision.releaseRemoteKeys {
        try session?.releaseInput(); commandState?.inputReleasedForShortcut(from:self); clearInput(resetShortcuts: false)
      }
      switch decision.route {
      case .remote: return true
      case .suppress: break
      case .releaseKeyboard: releaseKeyboardForCommand()
      case .captureKeyboard: try captureKeyboardForCommand()
      case .toggleFullscreen: try commandState?.perform(.fullscreen)
      case .contextMenu:
        setFocus(false); onContextMenu?(self); updateFocus()
      }
    } catch {
      _ = send { try $0.releaseInput() }; commandState?.inputReleasedForShortcut(from:self); clearInput()
      onError?(NativePresentationIssue(error:error,context:.shortcut).message)
    }
    return false
  }
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard ownsInputRoute, window?.firstResponder === self, session?.isFocused == true else { return false }
    var modifiers: NativeShortcutModifiers = []
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    guard capture.isActive || shortcutRouter?.routesKeyEquivalents == true ||
      (!shortcutModifiers.isEmpty && modifiers.isSuperset(of: shortcutModifiers)) else { return false }
    keyDown(with: event); return true
  }
  public override func becomeFirstResponder() -> Bool { setFocus(NSApp.isActive && window?.isKeyWindow == true && !isHiddenOrHasHiddenAncestor); return true }
  public override func resignFirstResponder() -> Bool { setFocus(false); return true }
  private func send(_ operation: (NativeSession) throws -> Void) -> Bool {
    guard ownsInputRoute, let session, !session.isClosing else { return false }
    do { try operation(session); return true }
    catch let error as NativeError where [.notConnected, .viewOnly, .unfocused, .closing, .stale].contains(error.status) { return false }
    catch { onError?(NativePresentationIssue(error:error,context:.input).message); return false }
  }
  private func pointer(_ event: NSEvent, changing button: UInt32 = 0, down: Bool? = nil) {
    guard commandState?.isMinimizing != true, let geometry else { return }
    let point = convert(event.locationInWindow, from: nil)
    cursorPoint = point; updateCursor()
    guard ownsInputRoute, session?.isViewOnly == false else { return }
    if buttons == 0 && !geometry.rectangle.contains(point) { return }
    if let down { if down { buttons |= button } else { buttons &= ~button } }
    lastPointer = point
    if let remote = try? geometry.remotePoint(point) { _ = send { try $0.sendPointer(x: remote.x, y: remote.y, buttons: buttons) } }
  }
  public override func mouseEntered(with event: NSEvent) { onFullscreenPointerEntered?(); cursorPoint = convert(event.locationInWindow, from: nil); updateCursor() }
  public override func mouseExited(with event: NSEvent) { cursorPoint = nil; clearCursor(); updateCursor() }
  public override func mouseDown(with event: NSEvent) { _ = focusDesktop(); pointer(event, changing: 1, down: true) }
  public override func mouseUp(with event: NSEvent) { pointer(event, changing: 1, down: false) }
  public override func rightMouseDown(with event: NSEvent) { _ = focusDesktop(); pointer(event, changing: 4, down: true) }
  public override func rightMouseUp(with event: NSEvent) { pointer(event, changing: 4, down: false) }
  public override func otherMouseDown(with event: NSEvent) { _ = focusDesktop(); if event.buttonNumber == 2 { pointer(event, changing: 2, down: true) } }
  public override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { pointer(event, changing: 2, down: false) } }
  public override func mouseMoved(with event: NSEvent) { pointer(event) }
  public override func mouseDragged(with event: NSEvent) { pointer(event) }
  public override func rightMouseDragged(with event: NSEvent) { pointer(event) }
  public override func otherMouseDragged(with event: NSEvent) { pointer(event) }
  public override func scrollWheel(with event: NSEvent) {
    guard ownsInputRoute, commandState?.isMinimizing != true, session?.isViewOnly == false, let geometry, geometry.rectangle.contains(convert(event.locationInWindow, from: nil)),
          let point = try? geometry.remotePoint(convert(event.locationInWindow, from: nil)) else { return }
    let factor = event.hasPreciseScrollingDeltas ? 40.0 : 1.0
    wheelX = max(-32, min(32, wheelX + event.scrollingDeltaX/factor))
    wheelY = max(-32, min(32, wheelY + event.scrollingDeltaY/factor))
    while abs(wheelY) >= 1 || abs(wheelX) >= 1 {
      let bit: UInt32
      if abs(wheelY) >= 1 { bit = wheelY > 0 ? 8 : 16; wheelY += wheelY > 0 ? -1 : 1 }
      else { bit = wheelX > 0 ? 32 : 64; wheelX += wheelX > 0 ? -1 : 1 }
      guard send({ try $0.sendPointer(x: point.x, y: point.y, buttons: buttons | bit) }),
            send({ try $0.sendPointer(x: point.x, y: point.y, buttons: buttons) }) else { break }
    }
  }
  private func keyDown(_ code: UInt16, _ symbol: UInt32) {
    guard symbol != 0 else { return }
    if send({ try $0.sendKey(id: UInt32(code)+1, keysym: symbol, keycode: native_macos_qnum(code), down: true) }) { held[code] = symbol }
  }
  public override func keyDown(with event: NSEvent) {
    guard routeShortcut(event, down: true), session?.isViewOnly == false else { return }
    let special = native_macos_special_keysym(event.keyCode)
    if special != 0 && !hasMarkedText() { keyDown(event.keyCode, special); return }
    if !event.modifierFlags.intersection([.control, .command]).isEmpty,
       let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
      keyDown(event.keyCode, native_unicode_keysym(scalar.value)); return
    }
    interpreting = event; wasComposing = hasMarkedText()
    interpretKeyEvents([event]); interpreting = nil; wasComposing = false
  }
  public override func keyUp(with event: NSEvent) {
    guard routeShortcut(event, down: false), let symbol = held.removeValue(forKey: event.keyCode) else { return }
    _ = send { try $0.sendKey(id: UInt32(event.keyCode)+1, keysym: symbol, keycode: native_macos_qnum(event.keyCode), down: false) }
    commandState?.physicalModifierReleased(symbol,from:self)
  }
  public override func flagsChanged(with event: NSEvent) {
    guard ownsInputRoute, commandState?.isMinimizing != true else { return }
    if event.keyCode == 57 {
      let enabled = event.modifierFlags.contains(.capsLock)
      if enabled != capsLock {
        let symbol = native_macos_special_keysym(event.keyCode)
        if routeShortcut(event, down: true) { _ = send { try $0.sendKey(id: 58, keysym: symbol, keycode: native_macos_qnum(57), down: true) } }
        if routeShortcut(event, down: false) { _ = send { try $0.sendKey(id: 58, keysym: symbol, keycode: native_macos_qnum(57), down: false) } }
        capsLock = enabled
      }
      return
    }
    if native_macos_modifier_down(event.keyCode, UInt64(event.modifierFlags.rawValue)) != 0 {
      if routeShortcut(event, down: true) { keyDown(event.keyCode, native_macos_special_keysym(event.keyCode)) }
    } else if routeShortcut(event, down: false), let symbol = held.removeValue(forKey: event.keyCode) {
      _ = send { try $0.sendKey(id: UInt32(event.keyCode)+1, keysym: symbol, keycode: native_macos_qnum(event.keyCode), down: false) }
      commandState?.physicalModifierReleased(symbol,from:self)
    }
  }
  public func insertText(_ string: Any, replacementRange: NSRange) {
    guard ownsInputRoute, commandState?.isMinimizing != true else { unmarkText(); return }
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    let composing = hasMarkedText() || wasComposing; unmarkText()
    if let event = interpreting, !composing, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
      keyDown(event.keyCode, native_unicode_keysym(scalar.value)); return
    }
    // Committed IME text is one synthetic press/release per scalar. The physical
    // event producing that commit is not also sent, avoiding duplicate input.
    for scalar in text.unicodeScalars {
      let symbol = native_unicode_keysym(scalar.value), id = 0x10000 + scalar.value
      guard send({ try $0.sendKey(id: id, keysym: symbol, down: true) }),
            send({ try $0.sendKey(id: id, keysym: symbol, down: false) }) else { break }
    }
  }
  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard ownsInputRoute, commandState?.isMinimizing != true else { unmarkText(); return }
    marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    selection = selectedRange
  }
  public func unmarkText() { marked = NSAttributedString(string: ""); selection = NSRange(location: 0, length: 0) }
  public func hasMarkedText() -> Bool { marked.length != 0 }
  public func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
  public func selectedRange() -> NSRange { selection }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let rectangle = convert(CGRect(x: lastPointer.x, y: lastPointer.y, width: 1, height: 18), to: nil)
    return window?.convertToScreen(rectangle) ?? .zero
  }
  public override func doCommand(by selector: Selector) { if selector == #selector(cancelOperation(_:)) { unmarkText() } }
}

@MainActor
public struct NativeDesktop: NSViewRepresentable {
  @ObservedObject private var session: NativeSession
  private let onError: (String) -> Void
  private let onContextMenu: ((NSView) -> Void)?
  private let displays: NativeDisplayService?
  private let commands: NativeDesktopCommands?
  private let input: NativeInputState?
  private let scaling: NativeScalingState?
  private let fullscreen: NativeFullscreenState?
  public init(session: NativeSession, displays: NativeDisplayService? = nil, scaling: NativeScalingState? = nil, input: NativeInputState? = nil, commands: NativeDesktopCommands? = nil, fullscreen: NativeFullscreenState? = nil, onContextMenu: ((NSView) -> Void)? = nil, onError: @escaping (String) -> Void = { _ in }) {
    self.fullscreen = fullscreen
    self.session = session; self.displays = displays; self.scaling = scaling; self.input = input; self.commands = commands; self.onContextMenu = onContextMenu; self.onError = onError
  }
  public func makeNSView(context: Context) -> NativeDesktopView { NativeDesktopView(frame: .zero) }
  public func updateNSView(_ view: NativeDesktopView, context: Context) { view.onError = onError; view.onContextMenu = onContextMenu; view.bind(session); view.observeDisplays(displays); view.observeScaling(scaling); view.observeInput(input); view.observeCommands(commands); view.observeFullscreen(fullscreen) }
  public static func dismantleNSView(_ view: NativeDesktopView, coordinator: ()) { view.detach() }
}


extension NativeDesktopView: NativeDesktopCommandHost {
  func refreshCommandFocus() { updateFocus(); updateAutomaticResize() }
  var commandWindow: NSWindow? { window }
  var commandViewport: CGSize { bounds.size }
  var commandDesktopSize: CGSize { desktopRectangle.size }
  func canPan(_ direction: NativeDesktopPan) -> Bool {
    guard commandState?.isMinimizing != true, session?.isClosing == false, lastState == .connected, let window, window.attachedSheet == nil,
          !isHiddenOrHasHiddenAncestor, let desiredGeometry else { return false }
    return desiredGeometry.panned(direction) != desiredGeometry.panPosition
  }
  func panDesktop(_ direction: NativeDesktopPan) -> Bool {
    guard canPan(direction), let desiredGeometry else { return false }
    if let canvasCoordinator {
      do { try canvasCoordinator.setPan(desiredGeometry.panned(direction)) }
      catch { onError?(NativePresentationIssue(error:error,context:.layout).message); return false }
    } else { pan = desiredGeometry.panned(direction) }
    return true
  }
  func focusForCommand() -> Bool {
    guard commandState?.isMinimizing != true, NSApp.isActive, !isHiddenOrHasHiddenAncestor,
          window?.isKeyWindow == true, window?.attachedSheet == nil,
          window?.makeFirstResponder(self) == true else { return false }
    return setFocus(true)
  }
  func captureKeyboardForCommand() throws {
    guard captureEligible else { throw NativeDesktopCommandIssue.unavailable }
    switch capture.start() {
    case .active: break
    case .accessibilityRequired:
      commandState?.captureChanged(false, message: NativePresentationIssue.keyboardCaptureUnavailable.message,from:self)
      throw NativeDesktopCommandIssue.keyboardCaptureUnavailable
    case .failed:
      commandState?.captureChanged(false, message: NativePresentationIssue.keyboardCaptureFailed.message,from:self)
      throw NativeDesktopCommandIssue.keyboardCaptureFailed
    }
    captureWasActive = true; captureSuppressed = false; commandState?.captureChanged(true,from:self)
  }
  func releaseKeyboardForCommand() {
    if captureWasActive { _ = send { try $0.releaseInput() }; commandState?.inputReleasedForShortcut(from:self); clearInput(resetShortcuts: false) }
    capture.stop(); captureWasActive = false; captureSuppressed = true; commandState?.captureChanged(false,from:self)
  }
  func clearCommandInput() { clearInput() }
}
