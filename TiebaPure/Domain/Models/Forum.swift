import Foundation

struct Forum: Identifiable, Equatable, Codable, Sendable {
    var id: Int64
    var name: String
    var displayName: String
    var avatarURL: URL?
    var memberCount: Int
    var threadCount: Int
}

/// The signed-in account's standing inside one followed forum.
struct FollowedForumStatus: Equatable, Sendable, Identifiable {
    var forumID: Int64
    /// The account's membership level in this forum (0 when unreported).
    var level: Int
    /// Whether the account has already checked in today.
    var isSignedToday: Bool
    var avatarURL: URL? = nil

    var id: Int64 { forumID }
}
