import Foundation
import Testing
@testable import Annotate

/// The menu's first row — the only part of the app that reports, in words, how
/// many marks are live right now.
///
/// It is worth pinning because the wording is the app's own status voice and it
/// was previously spelled twice: once as a literal when the menu was built, and
/// once in the updater. Nothing called the updater at launch, so the two could
/// drift apart and the launch state would silently win.

@Test("the live-annotation count reads as a sentence, singular and plural",
      arguments: [
        (0, "No annotations"),
        (1, "1 annotation live"),
        (2, "2 annotations live"),
        (64, "64 annotations live"),
      ])
@MainActor
func theLiveAnnotationCountReadsAsASentence(count: Int, expected: String) {
    #expect(AnnotateServices.statusTitle(count: count) == expected)
}

/// Clear All's key equivalent is ⌫, and naming the constant must not have moved
/// it. `NSBackspaceCharacter` is the same scalar the raw `"\u{08}"` escape was;
/// this is the assertion that says so out loud.
@Test("Clear All's key equivalent is still the backspace scalar")
@MainActor
func clearAllsKeyEquivalentIsStillTheBackspaceScalar() {
    #expect(AppDelegate.backspaceKeyEquivalent == "\u{08}")
}

/// The cap is 64 and the wording must survive it — this is the busiest the row
/// can ever legitimately get, and it is still plural prose, not a number.
@Test("the count wording holds at the store's live cap")
@MainActor
func theCountWordingHoldsAtTheStoresLiveCap() {
    #expect(AnnotateServices.statusTitle(count: AnnotationStore.defaultMaximumLiveAnnotations)
            == "64 annotations live")
}
