import Foundation

struct AnnotationLifetimeSchedule: Equatable {
    let receivedAt: Date
    let renderStart: Date
    let fadeStart: Date?
    let expiry: Date?

    init(ttlSeconds: Double, receivedAt: Date, renderStartDelay: TimeInterval) {
        self.receivedAt = receivedAt
        renderStart = receivedAt.addingTimeInterval(max(0, renderStartDelay))
        guard ttlSeconds > 0 else {
            fadeStart = nil
            expiry = nil
            return
        }
        fadeStart = renderStart.addingTimeInterval(max(0, ttlSeconds - 0.35))
        expiry = renderStart.addingTimeInterval(ttlSeconds)
    }
}

@MainActor
final class AnnotationStore {
    private struct Entry {
        let annotation: Annotation
        let lifetime: AnnotationLifetimeSchedule
        let fadeWorkItem: DispatchWorkItem?
        let expiryWorkItem: DispatchWorkItem?
    }

    /// How many marks may be live at once before the oldest is evicted.
    ///
    /// The cap exists so a runaway agent cannot pile up unbounded layers, not to
    /// ration ordinary use — a guided tour of a dense app legitimately wants
    /// dozens of marks on screen at once, and the debug showcase alone draws 35.
    /// It sat at 32 and silently ate the first three marks of any larger batch,
    /// which read as a rendering bug rather than a policy.
    static let defaultMaximumLiveAnnotations = 64

    private let maximumLiveAnnotations: Int
    private let clock: () -> Date
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    /// How many marks are on screen. Read when a clear finds nothing, so the
    /// reply can tell "your id is stale" from "the board is already empty".
    var liveCount: Int { order.count }

    var renderStartDelayProvider: (() -> TimeInterval)?
    var onInserted: ((Annotation, TimeInterval) -> Void)?
    var onRemoving: ((Annotation) -> Void)?
    var onFading: ((Annotation) -> Void)?
    var onCountChanged: ((Int) -> Void)?
    /// Fired once at the start of a clear-all (nil id), before the per-annotation
    /// fades, so the overlay can play the chalkboard wipe over the whole batch.
    var onClearAll: (() -> Void)?

    init(maximumLiveAnnotations: Int = AnnotationStore.defaultMaximumLiveAnnotations, clock: @escaping () -> Date = Date.init) {
        self.maximumLiveAnnotations = maximumLiveAnnotations
        self.clock = clock
    }

    var liveAnnotations: [Annotation] {
        order.compactMap { entries[$0]?.annotation }
    }

    func scheduledLifetime(for annotationID: UUID) -> AnnotationLifetimeSchedule? {
        entries[annotationID]?.lifetime
    }

    @discardableResult
    func insert(_ annotation: Annotation, renderStartDelay: TimeInterval? = nil) -> [Annotation] {
        var evicted: [Annotation] = []
        while entries.count >= maximumLiveAnnotations, let oldest = order.first, let annotation = remove(id: oldest) {
            evicted.append(annotation)
        }

        let delay = max(0, renderStartDelay ?? renderStartDelayProvider?() ?? 0)
        let schedule = AnnotationLifetimeSchedule(ttlSeconds: annotation.ttlSeconds, receivedAt: clock(), renderStartDelay: delay)
        let scheduled = scheduledWork(for: annotation, schedule: schedule)
        entries[annotation.id] = Entry(annotation: annotation, lifetime: schedule, fadeWorkItem: scheduled.fade, expiryWorkItem: scheduled.expiry)
        order.append(annotation.id)
        onInserted?(annotation, delay)
        announceCount()
        return evicted
    }

    @discardableResult
    func clear(annotationID: String?) -> Int {
        if let annotationID {
            guard let id = UUID(uuidString: annotationID), remove(id: id) != nil else { return 0 }
            return 1
        }
        let ids = order
        guard !ids.isEmpty else { return 0 }
        onClearAll?()
        ids.forEach { _ = remove(id: $0) }
        return ids.count
    }

    private func scheduledWork(for annotation: Annotation, schedule: AnnotationLifetimeSchedule) -> (fade: DispatchWorkItem?, expiry: DispatchWorkItem?) {
        guard let fadeStart = schedule.fadeStart, let expiry = schedule.expiry else { return (nil, nil) }
        let fade = DispatchWorkItem { [weak self] in self?.beginFade(id: annotation.id) }
        let removal = DispatchWorkItem { [weak self] in _ = self?.remove(id: annotation.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fadeStart.timeIntervalSince(schedule.receivedAt)), execute: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSince(schedule.receivedAt)), execute: removal)
        return (fade, removal)
    }

    private func beginFade(id: UUID) {
        guard let entry = entries[id] else { return }
        onFading?(entry.annotation)
    }

    @discardableResult
    private func remove(id: UUID) -> Annotation? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.fadeWorkItem?.cancel()
        entry.expiryWorkItem?.cancel()
        order.removeAll { $0 == id }
        onFading?(entry.annotation)
        onRemoving?(entry.annotation)
        announceCount()
        return entry.annotation
    }

    private func announceCount() {
        onCountChanged?(entries.count)
    }
}
