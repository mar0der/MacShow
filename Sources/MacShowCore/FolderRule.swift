import Foundation
import GRDB

/// What a folder (or a single file) holds, set by the user. Anything without a
/// rule is treated as the library's normal, commercial content.
public struct FolderRule: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Never scanned; nothing under it is in the library.
        case excluded
        /// Personal recordings: its videos are Home Videos, whatever their length.
        case personal
        /// Kept out of every screen, search and Home; shown only in the locked Adult section.
        case adult
    }

    public static let databaseTableName = "folderRule"

    /// Canonical path of the folder or file.
    public var path: String
    public var kind: Kind
    public var id: String { path }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// Looks up the rule that applies to a path: the one for the innermost folder containing it.
public struct FolderRules: Sendable {
    private let rules: [FolderRule]

    public init(_ rules: [FolderRule] = []) {
        self.rules = rules.sorted { $0.path.count > $1.path.count }
    }

    public func kind(for path: String) -> FolderRule.Kind? {
        rules.first { path == $0.path || path.hasPrefix($0.path + "/") }?.kind
    }

    public var excludedPaths: [String] { rules.filter { $0.kind == .excluded }.map(\.path) }
}

extension LibraryDatabase {
    public func folderRules() throws -> [FolderRule] {
        try writer.read { db in try FolderRule.order(Column("path")).fetchAll(db) }
    }

    /// Sets (or with nil, clears) the rule for `path`. Excluding a path removes
    /// what was indexed under it straight away.
    public func setFolderRule(_ kind: FolderRule.Kind?, for path: String) throws {
        try writer.write { db in
            _ = try FolderRule.deleteOne(db, key: path)
            guard let kind else { return }
            try FolderRule(path: path, kind: kind).insert(db)
            if kind == .excluded {
                let inside = Self.inside(path)
                try db.execute(sql: "DELETE FROM mediaItem WHERE path = ? OR \(inside.sql)", arguments: [path] + inside.arguments)
            }
        }
    }

    static func registerFolderRuleMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-folder-rules") { db in
            try db.create(table: "folderRule") { t in
                t.primaryKey("path", .text)
                t.column("kind", .text).notNull()
            }
        }
    }
}
