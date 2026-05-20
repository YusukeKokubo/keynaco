import KeynacoCore

extension InputController {
    static func extractVirtualHistory(from before: String) -> [String] {
        VirtualHistoryExtractor.extract(from: before)
    }
}
