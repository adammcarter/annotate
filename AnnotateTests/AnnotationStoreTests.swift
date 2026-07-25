import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// Annotation lifecycle: when a mark starts drawing, when it begins fading, when
/// it expires, and what gets evicted when the live cap is reached.

@Test("fade and expiry are anchored at the scheduled render start")
@MainActor
func annotationStoreAnchorsFadeAndExpiryAtTheScheduledRenderStart() throws {
    let receivedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let annotation = Annotation.fixture(ttlSeconds: 1)
    let store = AnnotationStore(clock: { receivedAt })
    _ = store.insert(annotation, renderStartDelay: 0.48)
    let schedule = try #require(store.scheduledLifetime(for: annotation.id))

    let fadeStart = try #require(schedule.fadeStart)
    let expiry = try #require(schedule.expiry)

    #expect(schedule.renderStart == receivedAt.addingTimeInterval(0.48))
    #expect(fadeStart == receivedAt.addingTimeInterval(1.13))
    #expect(expiry == receivedAt.addingTimeInterval(1.48))
}

/// The TTL half of this really does wait on the wall clock. The store's
/// injectable clock only stamps the schedule — expiry itself is a
/// `DispatchQueue.main.asyncAfter` work item, so nothing but real elapsed time
/// fires it. Sleeping yields the main actor, which is exactly what lets that
/// work item run.
@Test("the oldest annotation is evicted, and a TTL expires on its own")
@MainActor
func annotationStoreEvictsOldestAndExpiresTTL() async throws {
    let store = AnnotationStore(maximumLiveAnnotations: 2)
    let first = Annotation.fixture(ttlSeconds: 0)
    let second = Annotation.fixture(ttlSeconds: 0)
    let third = Annotation.fixture(ttlSeconds: 0)
    _ = store.insert(first)
    _ = store.insert(second)
    #expect(store.insert(third).map(\.id) == [first.id])
    #expect(store.liveAnnotations.map(\.id) == [second.id, third.id])
    let expiring = Annotation.fixture(ttlSeconds: 0.06)
    _ = store.insert(expiring)
    try await Task.sleep(for: .milliseconds(120))
    #expect(!store.liveAnnotations.contains { $0.id == expiring.id })
}

@Test("clearing takes one annotation by id, or all of them")
@MainActor
func annotationStoreClearsOneAndAll() {
    let store = AnnotationStore()
    let first = Annotation.fixture(ttlSeconds: 0)
    let second = Annotation.fixture(ttlSeconds: 0)
    _ = store.insert(first)
    _ = store.insert(second)
    #expect(store.clear(annotationID: first.id.uuidString) == 1)
    #expect(store.clear(annotationID: "not-a-uuid") == 0)
    #expect(store.clear(annotationID: nil) == 1)
}
