import AppKit

// MARK: - SegmentizeLRUCache

/// segmentize 結果の LRU キャッシュ。`Task.detached` から参照されるため class（参照型）。
public final class SegmentizeLRUCache: @unchecked Sendable {
    private let capacity: Int
    private var keys: [String] = []
    private var values: [[( reading: String, candidates: [String])]] = []
    private let lock = NSLock()

    /// 直近この件数までの segmentize 結果を保持する。
    public static let defaultCapacity = 50

    public init(capacity: Int = SegmentizeLRUCache.defaultCapacity) {
        self.capacity = capacity
    }

    func get(_ key: String) -> [(reading: String, candidates: [String])]? {
        lock.withLock {
            guard let idx = keys.firstIndex(of: key) else { return nil }
            let val = values[idx]
            // MRU へ移動
            keys.remove(at: idx); values.remove(at: idx)
            keys.append(key); values.append(val)
            return val
        }
    }

    func set(_ key: String, _ value: [(reading: String, candidates: [String])]) {
        lock.withLock {
            if let idx = keys.firstIndex(of: key) {
                keys.remove(at: idx); values.remove(at: idx)
            } else if keys.count >= capacity {
                keys.removeFirst(); values.removeFirst()
            }
            keys.append(key); values.append(value)
        }
    }
}
