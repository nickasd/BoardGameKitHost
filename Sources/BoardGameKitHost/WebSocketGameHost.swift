import Foundation
import Network

public class WebSocketGameHost: GameHost {
    
    public let lobby = Lobby()
    
    private let localServer: Server
    private let logger = Logger.shared
    private var users = [UUID: User]()
    private var connections = [User: NWConnection]()
    private var listener: NWListener?
    
    public init(port: Int, localServer: Server) throws {
        self.localServer = localServer
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let user = User(id: UUID(), name: "")
            logger.info("New connection for \(user)")
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        logger.info("Closed connection for \(user): \(error.localizedDescription)")
                        users.removeValue(forKey: user.id)
                        connections.removeValue(forKey: user)
                        connection.cancel()
                        disconnect(user: user)
                    case .ready:
                        listen(from: user)
                    case .cancelled:
                        logger.info("Cancelled connection for \(user)")
                        users.removeValue(forKey: user.id)
                        connections.removeValue(forKey: user)
                        disconnect(user: user)
                    default:
                        break
                    }
                }
            }
            Task { @MainActor in
                connections[user] = connection
            }
            connection.start(queue: .main)
        }
        listener.start(queue: .main)
        self.listener = listener
        logger.info("WebSocket listening on port \(port)")
    }
    
    public func close() {
        listener?.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        lobby.close()
    }
    
    private func disconnect(user: User) {
        logger.error("Disconnecting user \(user)")
        if let room = lobby.gameRooms.first(where: { $0.users.contains(user) }) {
            room.disconnected(user: user)
        } else {
            lobby.disconnected(user: user)
        }
    }
    
    private func listen(from user: User) {
        guard let connection = connections[user] else {
            return
        }
        connection.receiveMessage { [weak self] completeContent, contentContext, isComplete, error in
            guard let self else { return }
            if connection.state == .cancelled {
                return
            }
            Task { @MainActor in
                if let error = error {
                    logger.error(error.localizedDescription)
                    connection.cancel()
                    return
                }
                if let completeContent = completeContent {
                    receive(completeContent, from: user)
                }
                listen(from: user)
            }
        }
    }
    
    public func send<T: Collection>(_ data: RawRequest, to users: T) where T.Element == User {
        logger.debug("Server will send message: \(data.prettyPrinted) to \(users)")
        let data = RequestCoder.encode(data)
        if let localUser = User.local, users.contains(localUser) {
            Task {
                localServer.receive(data)
            }
        }
        for connection in users.compactMap({ connections[$0] }) {
            connection.send(content: data, contentContext: NWConnection.ContentContext(identifier: "send", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)]), completion: .contentProcessed({ [self] error in
                if let error = error {
                    logger.error(error.localizedDescription)
                }
            }))
        }
    }
    
    public func receive(_ data: RawRequest, from user: User) async throws {
        logger.info("Server received message: \(data.prettyPrinted) from \(user)")
        if data.name == RegisterRequest.name {
            try register(user: user, data: RequestCoder.decode(RegisterRequest.self, from: data.data))
        } else {
            try lobby.handle(user: user, action: data)
        }
    }
    
    public func saveGame(_ data: Data, name: String) throws {
        try LocalGames.shared.saveGame(data, name: name)
    }
    
    public func removeSavedGame(name: String) async throws {
        try LocalGames.shared.removeSavedGame(name: name)
    }
    
    // MARK: - Register
    
    public func registerLocalUser(_ user: User?) -> User {
        User.local = user ?? User(id: UUID(), name: NSUserName())
        lobby.addUser(User.local!)
        return User.local!
    }
    
    public struct RegisterRequest: Request {
        public static let name = "register"
        
        public let user: User?
        public let appVersion: String
        public let operatingSystemName: String
        public let operatingSystemVersion: String

        public init(user: User?) {
            self.user = user
            appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
            operatingSystemName = ProcessInfo.processInfo.operatingSystemName
            operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionShortString
        }
    }
    
    public struct RegisterResponse: Request {
        public static let name = "register"
        
        public let user: User
    }
    
    private func register(user: User, data: RegisterRequest) throws {
        if data.appVersion.compare(HostConfiguration.shared.minimumSupportedAppVersion, options: .numeric) == .orderedAscending {
            throw HostError(message: "The minimum supported app version is \(HostConfiguration.shared.minimumSupportedAppVersion).")
        }
        if !user.name.isEmpty {
            throw HostError(message: "User is already registered.")
        }
        if let userId = data.user?.id, let user = users[userId] {
            disconnect(user: user)
        }
        user.rename(id: data.user?.id ?? user.id, name: (data.user?.id ?? user.id).uuidString)
        users[user.id] = user
        send(RegisterResponse(user: user), to: [user])
        try lobby.enter(user: user)
    }
    
}

extension ProcessInfo {
    
    public var operatingSystemName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #endif
    }
    
    public var operatingSystemVersionShortString: String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    }
    
}
