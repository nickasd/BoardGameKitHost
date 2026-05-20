import Foundation

public class Logger: @unchecked Sendable {

    public enum Level: Int {
        case error
        case warn
        case info
        case debug
    }
    
    public enum FileMode {
        case staticFile(name: String)
        case rotatingFile
    }

    public static let shared = Logger(writeToFile: .rotatingFile, writeToConsole: true)
    
    static let logDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("logs")
    
    public var level: Level = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-log"), index < args.count - 1, let logLevel = Int(args[index + 1]).flatMap({ Level(rawValue: $0) }) {
            return logLevel
        }
        return .info
    }()
    var timestamp: Date?
    private(set) var url: URL?
    
    private let fileMode: FileMode?
    private let writeToConsole: Bool
    private let maxLogAgeInDays = TimeInterval(3)
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "BoardGameKit.Logger")
    
    private func timestampFormatStyle() -> Date.ISO8601FormatStyle {
        var format = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: true).dateTimeSeparator(.space).timeZone(separator: .omitted)
        format.timeZone = .current
        return format
    }
    
    private func fileNameFormatStyle() -> Date.ISO8601FormatStyle {
        var format = Date.ISO8601FormatStyle().year().month().day().dateTimeSeparator(.space)
        if #available(macOS 13.0, iOS 16.0, *) {
            format.timeZone = .gmt
        }
        return format
    }
    
    public init(writeToFile fileMode: FileMode?, writeToConsole: Bool) {
        self.fileMode = fileMode
        self.writeToConsole = writeToConsole
        if let fileMode = fileMode {
            do {
                try FileManager.default.createDirectory(atPath: Logger.logDirectory.path, withIntermediateDirectories: true)
                for url in try FileManager.default.contentsOfDirectory(at: Logger.logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    if let modificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, -modificationDate.timeIntervalSinceNow > 60 * 60 * 24 * maxLogAgeInDays {
                        try FileManager.default.removeItem(at: url)
                    }
                }
            } catch {
                fatalError(error.localizedDescription)
            }
            switch fileMode {
            case .staticFile(let filename):
                url = Logger.logDirectory.appendingPathComponent(filename)
            case .rotatingFile:
                setRotatingUrl()
                NotificationCenter.default.addObserver(self, selector: #selector(calendarDayChanged(_:)), name: .NSCalendarDayChanged, object: nil)
            }
        }
    }

    private func setRotatingUrl() {
        url = Logger.logDirectory.appendingPathComponent("\(Date().formatted(fileNameFormatStyle())).log")
        fileHandle?.closeFile()
        fileHandle = nil
    }
    
    @objc private func calendarDayChanged(_ notification: Notification) {
        queue.async { [self] in
            setRotatingUrl()
        }
    }
    
    private func log(_ callback: () throws -> String, _ level: Level) rethrows {
        if level.rawValue > self.level.rawValue {
            return
        }
        let timestamp = (timestamp ?? Date()).formatted(timestampFormatStyle())
        let message = try callback()
        
        if fileMode != nil {
            queue.async { [self] in
                if fileHandle == nil {
                    let url = url!
                    try? Data().write(to: url, options: .withoutOverwriting)
                    fileHandle = try! FileHandle(forWritingTo: url)
                    fileHandle!.seekToEndOfFile()
                }
                fileHandle!.write(Data("\(timestamp) \(message)\n".utf8))
            }
        }
        
        if writeToConsole {
            print("\(timestamp) \(message)")
        }
    }

    public func error(_ callback: @autoclosure () throws -> String) rethrows {
        try log(callback, .error)
    }
    
    public func warn(_ callback: @autoclosure () throws -> String) rethrows {
        try log(callback, .warn)
    }

    public func info(_ callback: @autoclosure () throws -> String) rethrows {
        try log(callback, .info)
    }

    public func debug(_ callback: @autoclosure () throws -> String) rethrows {
        try log(callback, .debug)
    }

}
