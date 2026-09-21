// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Session-owned renderers, including detached renderers that are still draining.
// A slot remains counted until cleanup completes, bounding rapid attach/detach.
@MainActor final class NativePresentationPool {
  private final class Slot {
    let scheduler: NativeTileScheduler
    let cursor: NativeCursorScheduler
    var cleanup: Task<Void, Never>?
    init(_ scheduler: NativeTileScheduler, cursor: NativeCursorScheduler) { self.scheduler = scheduler; self.cursor = cursor }
  }
  private var slots: [UUID: Slot] = [:]
  private var stopped = false
  var count: Int { slots.count }
  func acquire(renderer: (any NativeTileRendering)? = nil, cursorRenderer: (any NativeCursorRendering)? = nil) throws -> (UUID, NativeTileScheduler) {
    guard !stopped else { throw NativeError(.closing, "Desktop rendering is closing") }
    guard slots.count < 16 else { throw NativeError(.resourceLimit, "Too many desktop views are still rendering") }
    let worker = try renderer ?? NativeTileRenderer()
    let scheduler = NativeTileScheduler(renderer: worker), id = UUID()
    slots[id] = Slot(scheduler, cursor: NativeCursorScheduler(renderer: cursorRenderer ?? NativeCursorRenderer())); return (id, scheduler)
  }
  func cursor(_ id: UUID) -> NativeCursorScheduler? { slots[id]?.cursor }
  func release(_ id: UUID) {
    guard let slot = slots[id], slot.cleanup == nil else { return }
    slot.scheduler.stop(); slot.cursor.stop()
    slot.cleanup = Task { [weak self] in
      await slot.scheduler.close()
      await slot.cursor.close()
      self?.slots.removeValue(forKey: id)
    }
  }
  func stop() {
    stopped = true
    for id in Array(slots.keys) { release(id) }
  }
  func close() async {
    stop()
    let joins = slots.values.compactMap(\.cleanup)
    for join in joins { await join.value }
  }
}
