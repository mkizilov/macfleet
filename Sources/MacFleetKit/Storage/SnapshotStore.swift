import Foundation

public protocol SnapshotStoring: Sendable {
    func save(_ snapshot: SystemSnapshot) async
    func latest() async -> SystemSnapshot?
    /// Writes anything the store is holding back. Called before the machine sleeps and before the app quits.
    func flush() async
}

extension SnapshotStoring {
    public func flush() async {}
}

public actor InMemorySnapshotStore: SnapshotStoring {
    private let capacity: Int
    private var snapshots: [SystemSnapshot] = []

    public init(capacity: Int = 60) {
        self.capacity = capacity
    }

    public func save(_ snapshot: SystemSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > capacity {
            snapshots.removeFirst(snapshots.count - capacity)
        }
    }

    public func latest() -> SystemSnapshot? {
        snapshots.last
    }
}
