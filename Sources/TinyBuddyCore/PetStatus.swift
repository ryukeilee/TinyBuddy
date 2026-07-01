import Foundation

public enum PetStatus: String, CaseIterable, Identifiable, Equatable, Sendable {
    case idle
    case focusing
    case completedOnce

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idle:
            return "待机"
        case .focusing:
            return "专注中"
        case .completedOnce:
            return "完成一次"
        }
    }

    public var shortMood: String {
        switch self {
        case .idle:
            return "准备好了"
        case .focusing:
            return "保持专注"
        case .completedOnce:
            return "做得不错"
        }
    }
}
