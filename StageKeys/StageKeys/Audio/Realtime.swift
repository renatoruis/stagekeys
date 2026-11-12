import Darwin
import Foundation
import os

/// Unfair lock in stable memory. The render thread only ever calls `tryLock`, so it never waits.
final class RTLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(pointer) }
    @inline(__always) func tryLock() -> Bool { os_unfair_lock_trylock(pointer) }
}

/// Fixed-capacity FIFO of trivial values. Producers lock; the consumer (render thread) try-locks.
final class EventRing<Element> {
    private struct Cursor {
        var head = 0
        var count = 0
    }

    private let lock = RTLock()
    private let storage: UnsafeMutablePointer<Element>
    private let cursor: UnsafeMutablePointer<Cursor>
    let capacity: Int

    init(capacity: Int, empty: Element) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: empty, count: capacity)
        cursor = .allocate(capacity: 1)
        cursor.initialize(to: Cursor())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        cursor.deinitialize(count: 1)
        cursor.deallocate()
    }

    @discardableResult
    func push(_ element: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cursor.pointee.count < capacity else { return false }
        storage[(cursor.pointee.head + cursor.pointee.count) % capacity] = element
        cursor.pointee.count += 1
        return true
    }

    /// Moves up to `limit` queued events into `out`. Returns 0 when a producer holds the lock; they stay queued.
    @inline(__always)
    func drain(into out: UnsafeMutablePointer<Element>, limit: Int) -> Int {
        guard lock.tryLock() else { return 0 }
        let moved = min(limit, cursor.pointee.count)
        var head = cursor.pointee.head
        for index in 0..<moved {
            out[index] = storage[head]
            head += 1
            if head == capacity { head = 0 }
        }
        cursor.pointee.head = head
        cursor.pointee.count -= moved
        lock.unlock()
        return moved
    }
}

/// Main thread posts `Control`; the render thread copies it when it changed and reports back `Report`.
/// Both payloads must be trivial (no class references) so copying never touches ARC.
final class RTMailbox<Control, Report> {
    private struct Box {
        var version: Int
        var control: Control
        var report: Report
    }

    private let lock = RTLock()
    private let box: UnsafeMutablePointer<Box>

    init(control: Control, report: Report) {
        box = .allocate(capacity: 1)
        box.initialize(to: Box(version: 1, control: control, report: report))
    }

    deinit {
        box.deinitialize(count: 1)
        box.deallocate()
    }

    /// Main thread.
    func post(_ body: (inout Control) -> Void) {
        lock.lock()
        body(&box.pointee.control)
        box.pointee.version &+= 1
        lock.unlock()
    }

    /// Main thread.
    func read() -> (version: Int, control: Control, report: Report) {
        lock.lock()
        defer { lock.unlock() }
        return (box.pointee.version, box.pointee.control, box.pointee.report)
    }

    /// Render thread. Copies the control when its version moved past `seen`.
    @inline(__always)
    func fetch(into control: UnsafeMutablePointer<Control>, seen: UnsafeMutablePointer<Int>) -> Bool {
        guard lock.tryLock() else { return false }
        let changed = box.pointee.version != seen.pointee
        if changed {
            control.pointee = box.pointee.control
            seen.pointee = box.pointee.version
        }
        lock.unlock()
        return changed
    }

    /// Render thread. Skipped when the lock is busy; the next cycle reports again.
    @inline(__always)
    func publish(_ report: UnsafePointer<Report>) {
        guard lock.tryLock() else { return }
        box.pointee.report = report.pointee
        lock.unlock()
    }
}

enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static let nanosPerTick = Double(timebase.numer) / Double(timebase.denom)

    @inline(__always) static func now() -> UInt64 { mach_absolute_time() }
}
