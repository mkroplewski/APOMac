import APOEngine
import CryptoKit
import Foundation

public struct ManagedProfile: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public let directory: URL

    public var configurationURL: URL { directory.appendingPathComponent("config.txt") }

    public init(id: UUID, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }

    /// Profiles are folders named after the profile; the identifier is
    /// derived from the (case-insensitive) folder name so it is stable
    /// across launches without any metadata file.
    static func identifier(forFolderName name: String) -> UUID {
        let digest = SHA256.hash(data: Data(name.precomposedStringWithCanonicalMapping.lowercased().utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Profiles live as plain Equalizer APO config folders in `~/APOMac`:
/// `~/APOMac/<Profile name>/config.txt` plus any included files.
public final class ProfileStore: @unchecked Sendable {
    public let profilesDirectory: URL
    /// Old profile identifiers (UUID strings) → new folder names, for profiles
    /// moved from the previous Application Support location.
    public private(set) var migratedProfileNames: [String: String] = [:]
    private let fileManager: FileManager

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("APOMac", isDirectory: true)
    }

    /// Earlier builds kept profiles in Application Support.
    public static var legacyDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("APOMac/Profiles", isDirectory: true)
    }

    /// `legacyProfilesDirectory` defaults to the old location only when the
    /// default profiles directory is used.
    public init(fileManager: FileManager = .default, profilesDirectory: URL? = nil, legacyProfilesDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.profilesDirectory = profilesDirectory ?? Self.defaultDirectory
        try? fileManager.createDirectory(at: self.profilesDirectory, withIntermediateDirectories: true)
        if let legacy = legacyProfilesDirectory ?? (profilesDirectory == nil ? Self.legacyDirectory : nil) {
            migrateLegacyProfiles(from: legacy)
        }
    }

    public func list() -> [ManagedProfile] {
        guard let directories = try? fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fileManager.fileExists(atPath: directory.appendingPathComponent("config.txt").path) else { return nil }
            return profile(at: directory)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Imports a complete Equalizer APO profile directory (config.txt plus any
    /// included files and impulse responses).
    @discardableResult
    public func importDirectory(_ source: URL, name: String? = nil) throws -> ManagedProfile {
        let config = source.appendingPathComponent("config.txt")
        guard fileManager.fileExists(atPath: config.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The folder “\(source.lastPathComponent)” does not contain a config.txt file."])
        }
        let destination = uniqueURL(in: profilesDirectory, baseName: normalizedName(name ?? source.lastPathComponent))
        try fileManager.copyItem(at: source, to: destination)
        return profile(at: destination)
    }

    /// Imports a single configuration file, such as an AutoEQ ParametricEQ.txt.
    @discardableResult
    public func importFile(_ source: URL, name: String? = nil) throws -> ManagedProfile {
        let text = ConfigurationParser.decode(try Data(contentsOf: source))
        let profile = try create(name: name ?? source.deletingPathExtension().lastPathComponent)
        try writeConfiguration(text, for: profile)
        return profile
    }

    /// Copies the profile folder into `destination` under a name that does
    /// not collide with existing items. Returns the created directory.
    @discardableResult
    public func export(_ profile: ManagedProfile, to destination: URL) throws -> URL {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = uniqueURL(in: destination, baseName: normalizedName(profile.name))
        try fileManager.copyItem(at: profile.directory, to: target)
        return target
    }

    @discardableResult
    public func create(name: String = "New Profile") throws -> ManagedProfile {
        let directory = uniqueURL(in: profilesDirectory, baseName: normalizedName(name))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "# APOMac profile — Equalizer APO syntax\nPreamp: 0 dB\n"
        try Data(text.utf8).write(to: directory.appendingPathComponent("config.txt"), options: .atomic)
        return profile(at: directory)
    }

    @discardableResult
    public func duplicate(_ profile: ManagedProfile) throws -> ManagedProfile {
        try ensureManaged(profile)
        let destination = uniqueURL(in: profilesDirectory, baseName: normalizedName(profile.name + " Copy"))
        try fileManager.copyItem(at: profile.directory, to: destination)
        return self.profile(at: destination)
    }

    /// Renames the profile folder. The returned profile has a new identifier.
    public func rename(_ profile: ManagedProfile, to name: String) throws -> ManagedProfile {
        try ensureManaged(profile)
        let newName = normalizedName(name)
        guard newName != profile.directory.lastPathComponent else { return profile }
        if newName.lowercased() == profile.directory.lastPathComponent.lowercased() {
            // Case-only rename on a case-insensitive volume: go through a temporary name.
            let temporary = profilesDirectory.appendingPathComponent(".rename-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: profile.directory, to: temporary)
            let destination = profilesDirectory.appendingPathComponent(newName, isDirectory: true)
            try fileManager.moveItem(at: temporary, to: destination)
            return self.profile(at: destination)
        }
        let destination = uniqueURL(in: profilesDirectory, baseName: newName)
        try fileManager.moveItem(at: profile.directory, to: destination)
        return self.profile(at: destination)
    }

    public func delete(_ profile: ManagedProfile) throws {
        try ensureManaged(profile)
        try fileManager.trashItem(at: profile.directory, resultingItemURL: nil)
    }

    /// Reads config.txt with the same decoding the engine uses, so legacy
    /// Windows-1252 and UTF-16 profiles are shown (and saved back) intact.
    public func readConfiguration(_ profile: ManagedProfile) throws -> String {
        ConfigurationParser.decode(try Data(contentsOf: profile.configurationURL))
    }

    public func writeConfiguration(_ text: String, for profile: ManagedProfile) throws {
        try Data(text.utf8).write(to: profile.configurationURL, options: .atomic)
    }

    /// Latest modification date of the profile's files other than config.txt
    /// (included files, impulse responses), to notice external edits.
    func supportingFilesSignature(for profile: ManagedProfile) -> Date? {
        guard let enumerator = fileManager.enumerator(at: profile.directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var latest: Date?
        for case let url as URL in enumerator where url.lastPathComponent.lowercased() != "config.txt" {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                latest = max(latest ?? date, date)
            }
        }
        return latest
    }

    /// Folder names are profile names, so strip path separators and names
    /// that would refer to a parent or current folder.
    func normalizedName(_ name: String) -> String {
        var safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while safe.hasPrefix(".") { safe.removeFirst() }
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "New Profile" : String(safe.prefix(120))
    }

    private func profile(at directory: URL) -> ManagedProfile {
        let name = directory.lastPathComponent
        return ManagedProfile(id: ManagedProfile.identifier(forFolderName: name), name: name, directory: directory)
    }

    private func uniqueURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    /// Only folders directly inside the store may be renamed or deleted. Ask
    /// the file system instead of comparing URLs: the volume is usually case
    /// insensitive and paths may go through symlinks.
    private func ensureManaged(_ profile: ManagedProfile) throws {
        var relationship = FileManager.URLRelationship.other
        let parent = profile.directory.deletingLastPathComponent()
        try? fileManager.getRelationship(&relationship, ofDirectoryAt: profilesDirectory, toItemAt: parent)
        guard relationship == .same, fileManager.fileExists(atPath: profile.directory.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "The profile is outside APOMac's profile folder"])
        }
    }

    /// Earlier builds kept profiles as UUID-named folders (with a
    /// profile.json holding the name) in Application Support.
    private func migrateLegacyProfiles(from legacyProfiles: URL) {
        let legacyRoot = legacyProfiles.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(at: legacyProfiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        for entry in entries where fileManager.fileExists(atPath: entry.appendingPathComponent("config.txt").path) {
            let metadataURL = entry.appendingPathComponent("profile.json")
            let storedName = (try? Data(contentsOf: metadataURL))
                .flatMap { try? JSONDecoder().decode(LegacyMetadata.self, from: $0).name }
            let destination = uniqueURL(in: profilesDirectory, baseName: normalizedName(storedName ?? entry.lastPathComponent))
            do {
                try fileManager.moveItem(at: entry, to: destination)
                try? fileManager.removeItem(at: destination.appendingPathComponent("profile.json"))
                migratedProfileNames[entry.lastPathComponent.uppercased()] = destination.lastPathComponent
            } catch {
                continue
            }
        }
        // Remove the old folders only if nothing else is left in them.
        for directory in [legacyProfiles, legacyRoot] {
            let remaining = (try? fileManager.contentsOfDirectory(atPath: directory.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
            if remaining.isEmpty { try? fileManager.removeItem(at: directory) }
        }
    }
}

private struct LegacyMetadata: Codable {
    let name: String
}

/// Watches a file or directory (entries added, removed, renamed or
/// atomically replaced) and calls `handler` on the main queue, coalesced.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(url: URL, handler: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { handler() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}
