import AnnotateCore
import QuartzCore

struct ScheduledRenderStart: Equatable {
    let scheduledStart: CFTimeInterval
    let delay: CFTimeInterval
}

/// Staggers a burst of annotations so they draw one after another rather than
/// all at once — an agent that fires five marks in a single turn should look
/// like someone drawing, not like five things appearing.
///
/// The stagger is measured from ONE shared batch origin, not from each
/// annotation's own arrival, so slot N always lands N increments after the
/// batch started no matter how the requests were spaced inside the burst.
/// Requests more than 250 ms apart start a new batch. The total offset is
/// capped, so a large burst tightens up at the end instead of making the last
/// mark arrive noticeably late.
struct BurstStaggerScheduler {
    private var batchOrigin: CFTimeInterval?
    private var lastReceipt: CFTimeInterval?
    private var batchIndex = 0

    mutating func schedule(
        receivedAt: CFTimeInterval,
        stagger: CFTimeInterval = Tokens.stagger,
        cap: CFTimeInterval = Tokens.staggerCap
    ) -> ScheduledRenderStart {
        if let lastReceipt, let batchOrigin, receivedAt - lastReceipt < 0.25 {
            self.batchOrigin = batchOrigin
            batchIndex += 1
        } else {
            batchOrigin = receivedAt
            batchIndex = 0
        }
        lastReceipt = receivedAt

        let maximumSlot = max(0, Int((cap / stagger).rounded(.down)))
        let delayFromOrigin = min(CFTimeInterval(min(batchIndex, maximumSlot)) * stagger, cap)
        let scheduledStart = (batchOrigin ?? receivedAt) + delayFromOrigin
        return ScheduledRenderStart(scheduledStart: scheduledStart, delay: max(0, scheduledStart - receivedAt))
    }
}
