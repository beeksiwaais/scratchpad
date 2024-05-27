import Foundation

enum AppError: Error {
    case invalidArguments
    case scratchpadNotFound(String)
    case configError(String)
    case socketError(String)
}

struct Coordinate: Codable {
    var x: Int16
    var y: Int16

    init(from array: [Int16]) {
        self.x = array[0]
        self.y = array[1]
    }

    func toString() -> String {
        return "abs:\(x):\(y)"
    }
}

enum Target: Codable {
    case title(String)
    case app(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let targetStr = try container.decode(String.self)
        if targetStr.contains(".app") {
            self = .app(targetStr)
        } else {
            self = .title(targetStr)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .title(let title):
            try container.encode(title)
        case .app(let app):
            try container.encode(app)
        }
    }
}

enum LaunchOption: Codable {
    case application(String)
    case applicationWithArgs(String, [String])
    case command(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let commandStr = try container.decode(String.self)
        self = .command(commandStr)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .application(let app):
            try container.encode(app)
        case .applicationWithArgs(let app, let args):
            try container.encode([app] + args)
        case .command(let command):
            try container.encode(command)
        }
    }
}

struct Scratchpad: Codable {
    var name: String
    var target: Target
    var position: Coordinate
    var size: Coordinate
    var launchCommand: LaunchOption
    var launchTimeout: UInt8
    var scratchpadSpace: UInt8

    func toggle() throws {
        var targetWindow: Window? = try getTargetWindow()

        if targetWindow == nil {
            let timer = Date()
            try launch()

            while targetWindow == nil {
                targetWindow = try getTargetWindow()

                if Date().timeIntervalSince(timer) > Double(launchTimeout) {
                    throw AppError.configError("Application didn't launch within timeout period!")
                }

                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        guard let targetWindow = targetWindow else { return }
        let windowID = targetWindow.id

        if targetWindow.hasFocus {
            try querySocket(command: ["window", String(windowID), "--space", String(scratchpadSpace)])
            return
        }

        let focusedSpaceID = try getFocusedSpace()!.index

        if !targetWindow.isFloating {
            try querySocket(command: ["window", String(windowID), "--toggle", "float"])
        }

        try querySocket(command: ["window", String(windowID), "--space", String(focusedSpaceID)])
        try querySocket(command: ["window", String(windowID), "--move", position.toString()])
        try querySocket(command: ["window", String(windowID), "--resize", size.toString()])
        try querySocket(command: ["window", "--focus", String(windowID)])
    }

    func launch() throws {
        switch launchCommand {
        case .application(let app):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "/Applications/\(app)"]
            try process.run()
            process.waitUntilExit()

        case .applicationWithArgs(let app, let args):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "/Applications/\(app)", "--args"] + args
            try process.run()
            process.waitUntilExit()

        case .command(let command):
            let components = command.split(separator: " ").map(String.init)
            guard let executable = components.first else { return }
            let args = Array(components.dropFirst())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
            try process.run()
            process.waitUntilExit()
        }
    }

    func getTargetWindow() throws -> Window? {
        let windows = try getWindows()
        switch target {
        case .title(let title):
            return windows.first(where: { $0.title == title })
        case .app(let app):
            return windows.first(where: { $0.app == app })
        }
    }

    func getFocusedSpace() throws -> Space? {
        let spaces = try getSpaces()
        return spaces.first(where: { $0.hasFocus })
    }

    func getWindows() throws -> [Window] {
        let response = try querySocket(command: ["query", "--windows"])
        return try JSONDecoder().decode([Window].self, from: response.data(using: .utf8)!)
    }

    func getSpaces() throws -> [Space] {
        let response = try querySocket(command: ["query", "--spaces"])
        return try JSONDecoder().decode([Space].self, from: response.data(using: .utf8)!)
    }
}

struct Config: Codable {
    var launchTimeout: UInt8
    var scratchpadSpace: UInt8
    var scratchpads: [Scratchpad]

    static func getConfig() throws -> Config {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let configPath = homeDirectory.appendingPathComponent(".config/scratchpad/config.json")

        guard fileManager.fileExists(atPath: configPath.path) else {
            throw AppError.configError("Couldn't find scratchpad config file!")
        }

        let configData = try Data(contentsOf: configPath)
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(Config.self, from: configData) else {
            throw AppError.configError("Invalid config!")
        }

        return config
    }
}

struct Frame: Codable {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
}

struct Window: Codable {
    var id: UInt32
    var pid: UInt32
    var app: String
    var title: String
    var frame: Frame
    var role: String
    var subrole: String
    var display: UInt8
    var space: UInt8
    var level: Int16
    var opacity: Float
    var splitType: String
    var stackIndex: UInt8
    var canMove: Bool
    var canResize: Bool
    var hasFocus: Bool
    var hasShadow: Bool
    var hasParentZoom: Bool
    var hasFullscreenZoom: Bool
    var isNativeFullscreen: Bool
    var isVisible: Bool
    var isMinimized: Bool
    var isHidden: Bool
    var isFloating: Bool
    var isSticky: Bool
    var isGrabbed: Bool
}

struct Space: Codable {
    var id: UInt32
    var uuid: String
    var index: UInt32
    var label: String
    var spaceType: String
    var display: UInt8
    var windows: [UInt32]
    var firstWindow: UInt32
    var lastWindow: UInt32
    var hasFocus: Bool
    var isVisible: Bool
    var isNativeFullscreen: Bool
}

func formatMessage(message: [String]) -> Data {
    var command = Data([0x0, 0x0, 0x0, 0x0])
    for token in message {
        if let tokenData = token.data(using: .utf8) {
            command.append(tokenData)
            command.append(0x0)
        }
    }
    command.append(0x0)
    command[0] = UInt8(command.count - 4)
    return command
}

func getSocketStream() throws -> FileHandle {
    let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
    let socketPath = "/tmp/yabai_\(user).socket"

    guard FileManager.default.fileExists(atPath: socketPath) else {
        throw AppError.socketError("Yabai socket doesn't exist! Is Yabai installed and running?")
    }

    let socket = try FileHandle(forUpdating: URL(fileURLWithPath: socketPath))
    return socket
}

func querySocket(command: [String]) throws -> String {
    let socket = try getSocketStream()
    let message = formatMessage(message: command)
    socket.write(message)
    
    var response = Data()
    while let chunk = try? socket.read(upToCount: 1024), !chunk.isEmpty {
        response.append(chunk)
    }
    return String(data: response, encoding: .utf8) ?? ""
}

func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        throw AppError.invalidArguments
    }

    let command = arguments[1]
    let name = arguments[2]

    guard command == "--toggle" else {
        throw AppError.invalidArguments
    }

    let config = try Config.getConfig()
    guard let scratchpad = config.scratchpads.first(where: { $0.name == name }) else {
        throw AppError.scratchpadNotFound(name)
    }

    try scratchpad.toggle()
}

do {
    try main()
} catch AppError.invalidArguments {
    print("Invalid arguments! Try 'scratchpad --toggle example' to toggle scratchpad named 'example'")
    exit(1)
} catch AppError.scratchpadNotFound(let name) {
    print("Didn't find scratchpad named '\(name)'")
    exit(1)
} catch {
    print("An unexpected error occurred: \(error)")
    exit(1)
}