# Contributing

Pull requests are welcome. Fork the repo, work on a branch, open a PR.

Everything merges through review by the maintainer — `main` takes no direct
pushes, and no PR lands without an approving review and a green CI run. If you
are planning something substantial, open an issue first so we can agree the
shape before you spend the time.

## Before you open a PR

```sh
swift test --package-path Packages/AnnotateCore
swift test --package-path Packages/AnnotateMCP
xcodebuild -project Annotate.xcodeproj -scheme Annotate -destination 'platform=macOS' test
```

Two things worth knowing if you touch anything that draws:

**Generator draw count and draw order are the pixel contract.** Every mark is
seeded from its annotation id, so the geometry is exactly reproducible and the
golden tests assert on real coordinates. Moving a draw between functions is safe;
reordering one silently changes every existing mark. There is a longer note at
the top of `PenStroke.swift`.

**An offline render is not proof.** Several bugs here looked perfect in a
rendered PNG and wrong on a real composited screen. Build the app, draw with it,
and look at the result before claiming a visual change works.

## Commits

One logical change per commit. Explain *why* in the message — the diff already
says what. If you found something surprising on the way, that is usually the most
valuable line in the message.
