import Foundation

public struct ManagedProfile: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let directory: URL

    public var configurationURL: URL { directory.appendingPathComponent("config.txt") }

    public init(id: UUID, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public final class ProfileStore: @unchecked Sendable {
    public let profilesDirectory: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default, profilesDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let profilesDirectory {
            self.profilesDirectory = profilesDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.profilesDirectory = applicationSupport.appendingPathComponent("APOMac/Profiles", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.profilesDirectory, withIntermediateDirectories: true)
    }

    public func list() -> [ManagedProfile] {
        guard let directories = try? fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let id = UUID(uuidString: directory.lastPathComponent),
                  fileManager.fileExists(atPath: directory.appendingPathComponent("config.txt").path) else { return nil }
            let nameURL = directory.appendingPathComponent("profile.json")
            let name = (try? Data(contentsOf: nameURL)).flatMap { try? JSONDecoder().decode(ProfileMetadata.self, from: $0).name } ?? directory.lastPathComponent
            return ManagedProfile(id: id, name: name, directory: directory)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func importDirectory(_ source: URL, name: String? = nil) throws -> ManagedProfile {
        let config = source.appendingPathComponent("config.txt")
        guard fileManager.fileExists(atPath: config.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The imported profile does not contain config.txt"])
        }
        let id = UUID()
        let destination = profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.copyItem(at: source, to: destination)
        let profileName = name ?? source.lastPathComponent
        try saveMetadata(ProfileMetadata(name: profileName), at: destination)
        return ManagedProfile(id: id, name: profileName, directory: destination)
    }

    public func export(_ profile: ManagedProfile, to destination: URL) throws {
        let target = destination.appendingPathComponent(profile.name, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: profile.directory, to: target)
        try? fileManager.removeItem(at: target.appendingPathComponent("profile.json"))
    }

    @discardableResult
    public func create(name: String = "New Profile") throws -> ManagedProfile {
        let id = UUID()
        let directory = profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "# APOMac profile\n# Add Equalizer APO-compatible commands here.\n"
        try text.data(using: .utf8)!.write(to: directory.appendingPathComponent("config.txt"), options: .atomic)
        let profileName = normalizedName(name)
        try saveMetadata(ProfileMetadata(name: profileName), at: directory)
        return ManagedProfile(id: id, name: profileName, directory: directory)
    }

    @discardableResult
    public func createDefault() throws -> ManagedProfile {
        try create(name: "Default")
    }

    public func rename(_ profile: ManagedProfile, to name: String) throws -> ManagedProfile {
        try ensureManaged(profile)
        let profileName = normalizedName(name)
        try saveMetadata(ProfileMetadata(name: profileName), at: profile.directory)
        return ManagedProfile(id: profile.id, name: profileName, directory: profile.directory)
    }

    public func delete(_ profile: ManagedProfile) throws {
        try ensureManaged(profile)
        try fileManager.removeItem(at: profile.directory)
    }

    public func readConfiguration(_ profile: ManagedProfile) -> String {
        (try? String(contentsOf: profile.configurationURL, encoding: .utf8)) ?? ""
    }

    public func writeConfiguration(_ text: String, for profile: ManagedProfile) throws {
        try text.data(using: .utf8)!.write(to: profile.configurationURL, options: .atomic)
    }

    private func saveMetadata(_ metadata: ProfileMetadata, at directory: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent("profile.json"), options: .atomic)
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.replacingOccurrences(of: "/", with: "-")
        return safe.isEmpty ? "New Profile" : safe
    }

    private func ensureManaged(_ profile: ManagedProfile) throws {
        let parent = profile.directory.deletingLastPathComponent().standardizedFileURL
        guard parent == profilesDirectory.standardizedFileURL,
              profile.directory.lastPathComponent == profile.id.uuidString else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "The profile is outside APOMac's profile store"])
        }
    }
}

private struct ProfileMetadata: Codable {
    let name: String
}
