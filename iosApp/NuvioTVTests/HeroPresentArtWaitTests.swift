import XCTest
@testable import NuvioTV
import UIKit

/// Unit tests for `HeroPresentArtWait` (`Screens/HomeView.swift`, round 3), the wait state behind
/// `HeroArtResolver.present(_:isFolder:)`. It replaced a `withTaskGroup` whose deadline child could
/// not actually bound the resolve: a group awaits every child on the way out even after
/// `cancelAll()`, and `ArtworkStore.fetch` parks on shared unstructured work that ignores waiter
/// cancellation by design, so a stalled backdrop deferred the hero PRESENTATION by the URLSession
/// timeout rather than by 400 ms.
///
/// The state machine is the only part of the resolve that is testable without a live view and a
/// network: `present` reaches `ArtworkStore.fetch` through a static, so there is no injection seam
/// for the fetch itself. The wiring around it (fetch tasks issued unstructured, deadline task
/// cancelled after the park, identity guard before the commit) stays covered by test20 and test31.
///
/// Every case drives the class the same way `present` does: attach a continuation, let a terminal
/// event resume it, then read what the commit would paint.
final class HeroPresentArtWaitTests: XCTestCase {

    /// Distinct 1x1 bitmaps. `HeroPresentation` compares images by REFERENCE (one decoded instance
    /// per URL out of `ArtworkStore`), so these assertions use `===` too.
    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @MainActor
    func testStalledBackdropResumesAtTheDeadlineWithTheCachedLogo() async {
        let cachedLogo = makeImage()
        // The shape of a cold hero swap: logo already resident, backdrop cold and then stalled.
        let wait = HeroPresentArtWait(backdrop: nil, logo: cachedLogo,
                                      needsBackdrop: true, needsLogo: false)

        // Same construction as `present`, with a short stand-in for `laterSwapDeadline`. No fetch
        // task at all here: that IS the stall, and the point is that it cannot hold the wait open.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            wait.deadlineElapsed()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }
        deadline.cancel()

        XCTAssertTrue(wait.hitDeadline, "the budget, not a fetch, ended this wait")
        XCTAssertNil(wait.backdrop, "nothing landed, so the commit paints no backdrop")
        XCTAssertTrue(wait.logo === cachedLogo, "the cached logo is committed, not a text wordmark")

        // The stalled fetch is never cancelled, so it still reports. By then its item has been
        // presented, and swapping art in behind the reader's eyes is the repaint BUG-90 removed.
        let lateBackdrop = makeImage()
        wait.resolveBackdrop(lateBackdrop)
        XCTAssertNil(wait.backdrop, "a backdrop that lands after the deadline is dropped")
        XCTAssertTrue(wait.logo === cachedLogo)
    }

    @MainActor
    func testBothFetchesLandingResumeBeforeTheDeadlineIsEverConsulted() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: true)
        let backdrop = makeImage()
        let logo = makeImage()

        // Both settle first, so the continuation is already spent when `attach` runs. `attach` must
        // resume it on the spot rather than parking forever.
        wait.resolveBackdrop(backdrop)
        wait.resolveLogo(logo)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "both pieces landed inside the budget")
        XCTAssertTrue(wait.backdrop === backdrop)
        XCTAssertTrue(wait.logo === logo)
    }

    @MainActor
    func testEmptyFetchResultLeavesTheCachedImageInPlace() async {
        let cachedBackdrop = makeImage()
        let wait = HeroPresentArtWait(backdrop: cachedBackdrop, logo: nil,
                                      needsBackdrop: true, needsLogo: false)

        // `try? await ArtworkStore.fetch(...)` hands back nil on a 404 or a decode failure. That
        // must not blank art the resolver already had.
        wait.resolveBackdrop(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline)
        XCTAssertTrue(wait.backdrop === cachedBackdrop)
        XCTAssertNil(wait.logo, "no logo means the hero draws its text wordmark")
    }

    @MainActor
    func testCancelWaitResumesWithoutClaimingTheDeadlineFired() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: true)

        // A superseded `present` cancels the resolve task; its cancellation handler calls this.
        Task { @MainActor in wait.cancelWait() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "cancellation is not a timeout")
        XCTAssertNil(wait.backdrop)
        XCTAssertNil(wait.logo)

        // The resolver's identity guard is what blocks the commit, but a cancelled wait must also
        // stop accepting arrivals so nothing can revive it.
        wait.resolveLogo(makeImage())
        XCTAssertNil(wait.logo)
    }
}
