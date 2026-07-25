import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// The two pure decisions the overlay makes before anything is drawn: which
/// display a mark lands on, and *when* each mark in a batch starts, so a burst
/// reads as someone drawing rather than as marks appearing all at once.
///
/// `OverlayEngine` itself — the window lifecycle, the fade bookkeeping and the
/// clear-all deadline — is NOT covered here. It needs live `NSScreen` panels,
/// and that gap is stated here rather than implied by a file
/// name.

@Test("the first display stays primary and secondaries sort by display ID")
@MainActor
func screenCatalogKeepsTheFirstDisplayPrimaryAndSortsSecondariesByDisplayID() {
    #expect(ScreenCatalog.orderedDisplayIDs([99, 42, 7, 13]) == [99, 7, 13, 42])
}

@Test("a burst of receipts staggers from one shared origin")
@MainActor
func burstStaggerUsesOneSharedOriginForEverySlot() {
    var scheduler = BurstStaggerScheduler()
    let first = scheduler.schedule(receivedAt: 10)
    let second = scheduler.schedule(receivedAt: 10.04)
    let third = scheduler.schedule(receivedAt: 10.08)
    let fourth = scheduler.schedule(receivedAt: 10.12)
    let fifth = scheduler.schedule(receivedAt: 10.16)
    let sixth = scheduler.schedule(receivedAt: 10.20)

    #expect(abs(first.scheduledStart - 10) < 0.0001)
    #expect(abs(second.scheduledStart - 10.12) < 0.0001)
    #expect(abs(third.scheduledStart - 10.24) < 0.0001)
    #expect(abs(fourth.scheduledStart - 10.36) < 0.0001)
    #expect(abs(fifth.scheduledStart - 10.48) < 0.0001)
    #expect(abs(sixth.scheduledStart - 10.48) < 0.0001)
    #expect(abs(sixth.delay - 0.28) < 0.0001)
}
