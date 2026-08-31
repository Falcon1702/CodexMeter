public enum UsageSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case healthy
    case warning
    case critical

    public init(remainingPercent: Double) {
        if remainingPercent >= 30 {
            self = .healthy
        } else if remainingPercent >= 10 {
            self = .warning
        } else {
            self = .critical
        }
    }
}
