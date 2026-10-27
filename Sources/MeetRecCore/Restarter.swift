import Foundation

final class Restarter {
    private let queue: DispatchQueue
    private let delays: [TimeInterval] = [0.5, 1, 2, 4]
    private var pending = false
    private var cancelled = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func cancel() {
        cancelled = true
    }

    func trigger(attempt: @escaping () throws -> Void, giveUp: @escaping (Error) -> Void) {
        guard !pending, !cancelled else { return }
        pending = true
        run(0, attempt, giveUp)
    }

    private func run(_ n: Int, _ attempt: @escaping () throws -> Void, _ giveUp: @escaping (Error) -> Void) {
        queue.asyncAfter(deadline: .now() + delays[n]) { [weak self] in
            guard let self, !self.cancelled else { return }
            do {
                try attempt()
                self.pending = false
            } catch {
                if n + 1 < self.delays.count {
                    self.run(n + 1, attempt, giveUp)
                } else {
                    self.pending = false
                    giveUp(error)
                }
            }
        }
    }
}
