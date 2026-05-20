import Foundation

public class LocalGameHost: GameHost {
    
    public let lobby = Lobby()
    
    private let localServer: Server
    private let logger = Logger.shared
    
    public init(localServer: Server) throws {
        self.localServer = localServer
    }
    
    public func close() {
        lobby.close()
    }
    
    public func send<T: Collection>(_ data: RawRequest, to users: T) where T.Element == User {
        logger.debug("Server will send message: \(data.prettyPrinted) to \(users)")
        if let localUser = User.local, users.contains(localUser) {
            Task { @MainActor in
                localServer.receive(RequestCoder.encode(data))
            }
        }
    }
    
    public func receive(_ data: RawRequest, from user: User) async throws {
        logger.info("Server received message: \(data.prettyPrinted) from \(user)")
        try lobby.handle(user: user, action: data)
    }
    
    public func saveGame(_ data: Data, name: String) async throws {
        try LocalGames.shared.saveGame(data, name: name)
    }
    
    public func removeSavedGame(name: String) async throws {
        try LocalGames.shared.removeSavedGame(name: name)
    }
    
    // MARK: - Register
    
    public func registerLocalUser(_ user: User) {
        User.local = user
        lobby.addUser(User.local!)
    }
    
}

final public class LocalGames: Sendable {
    
    public struct LocalGame {
        public let url: URL
        public let name: String
        let modificationDate: Date
    }
    
    public static let shared = LocalGames()
    
    private let logger = Logger.shared
    private let savedGamesUrl = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("saved games", isDirectory: true)
    private let archivedGamesUrl = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("archived games", isDirectory: true)
    
    public func savedGames() -> [URL] {
        return ((try? FileManager.default.contentsOfDirectory(at: savedGamesUrl, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []).map({ LocalGame(url: $0, name: $0.deletingPathExtension().lastPathComponent, modificationDate: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).sorted(by: { $0.modificationDate > $1.modificationDate }).map({ $0.url })
    }
    
    public func archivedGames() -> [URL] {
        return ((try? FileManager.default.contentsOfDirectory(at: archivedGamesUrl, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []).map({ LocalGame(url: $0, name: $0.deletingPathExtension().lastPathComponent, modificationDate: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).sorted(by: { $0.modificationDate > $1.modificationDate }).map({ $0.url })
    }
    
    public func saveUrl(forName name: String) -> URL {
        return savedGamesUrl.appendingPathComponent("\(name.replacingOccurrences(of: ":", with: "_")).\(SavedGame.fileExtension)")
    }
    
    public func archiveUrl(forName name: String) -> URL {
        return archivedGamesUrl.appendingPathComponent("\(name.replacingOccurrences(of: ":", with: "_")).\(SavedGame.fileExtension)")
    }
    
    public func name(fromUrl url: URL) -> String {
        return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: ":")
    }
    
    func saveGame(_ data: Data, name: String) throws {
        let url = saveUrl(forName: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    
    func removeSavedGame(name: String) throws {
        do {
            try FileManager.default.trashItem(at: saveUrl(forName: name), resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: saveUrl(forName: name))
        }
    }
    
    public func archiveGame(_ data: Data, name: String) throws {
        let url = archiveUrl(forName: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    
}
