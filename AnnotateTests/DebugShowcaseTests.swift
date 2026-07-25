import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// The "Draw Tool Showcase" debug menu action, and the one thing it can silently
/// get wrong: asking for more marks than the store is willing to keep alive.

/// The debug showcase must fit INSIDE the store's live-annotation cap.
///
/// It did not, and the failure was silent and misleading: adding the
/// underline row took the grid from 25 marks to 35, three past the cap, so
/// the three oldest — the Accent, Warn and OK circles — drew their entry
/// animation and were then evicted and faded. It read as a rendering bug in
/// the loops. It was the eviction policy doing exactly what it was told.
///
/// Pinned so the next tool row fails a test instead of quietly deleting the
/// top-left of the grid.

#if DEBUG

@Test("the debug showcase fits inside the live-annotation cap")
@MainActor
func theDebugShowcaseFitsInsideTheLiveAnnotationCap() {
    let screen = Rect(x: 0, y: 0, width: 1920, height: 1200)
    let showcase = DebugShowcase.annotations(mainScreen: screen)

    #expect(showcase.count <= AnnotationStore.defaultMaximumLiveAnnotations,
            "the showcase draws \(showcase.count) marks but the store only keeps \(AnnotationStore.defaultMaximumLiveAnnotations)")

    // And prove it end to end: every mark the showcase asks for is still live
    // once the whole grid has been inserted.
    let store = AnnotationStore()
    for annotation in showcase { store.insert(annotation) }
    #expect(store.liveAnnotations.count == showcase.count,
            "the showcase lost marks to eviction")
}

#endif
