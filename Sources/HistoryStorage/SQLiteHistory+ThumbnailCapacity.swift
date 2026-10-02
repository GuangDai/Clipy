import HistoryCore

extension SQLiteHistory {
    public func thumbnailCapacityChanges() async -> AsyncStream<Void> {
        await thumbnailService.capacityChanges()
    }
}
