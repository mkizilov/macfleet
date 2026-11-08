import Foundation

/// How a deadline race ended: the work finished first, or the deadline passed first.
enum DeadlineOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case timedOut
}

extension DeadlineOutcome: Equatable where Value: Equatable {}

/// Runs `work` against a deadline and returns whichever ends first.
///
/// The race is decided by a gate, not by a task group. A task group returns only after every child has finished, so
/// work that ignores cancellation would hold the caller past its deadline. Here the caller resumes as soon as either side
/// finishes. The loser is cancelled, and a late result is discarded, so nothing waits on work the caller has given up on.
func raceAgainstDeadline<Value: Sendable>(
    _ deadline: Duration,
    _ work: @escaping @Sendable () async -> Value
) async -> DeadlineOutcome<Value> {
    let gate = DeadlineGate<Value>()
    let worker = Task {
        await gate.finish(.finished(await work()))
    }
    let timer = Task {
        do {
            try await Task.sleep(for: deadline, clock: .suspending)
        } catch {
            return
        }
        await gate.finish(.timedOut)
    }
    let outcome = await gate.value
    timer.cancel()
    if case .timedOut = outcome {
        worker.cancel()
    }
    return outcome
}

/// Keeps the first outcome, and wakes the one caller that waits for it. A later outcome is ignored.
private actor DeadlineGate<Value: Sendable> {
    private var outcome: DeadlineOutcome<Value>?
    private var waiter: CheckedContinuation<DeadlineOutcome<Value>, Never>?

    var value: DeadlineOutcome<Value> {
        get async {
            if let outcome {
                return outcome
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>) in
                waiter = continuation
            }
        }
    }

    func finish(_ result: DeadlineOutcome<Value>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}
