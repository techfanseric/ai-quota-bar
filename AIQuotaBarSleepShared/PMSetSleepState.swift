import Foundation

public struct PMSetSleepState: Codable, Equatable {
    public var global: Bool?
    public var battery: Bool?
    public var charger: Bool?
    public var ups: Bool?

    public init(
        global: Bool? = nil,
        battery: Bool? = nil,
        charger: Bool? = nil,
        ups: Bool? = nil
    ) {
        self.global = global
        self.battery = battery
        self.charger = charger
        self.ups = ups
    }

    public var hasAnySource: Bool {
        global != nil
            || battery != nil
            || charger != nil
            || ups != nil
    }

    /// Whether sleep is disabled on every reported power source.
    /// Returns false when no source was reported, so callers treat an
    /// unreadable state as "not disabled" and re-assert.
    public var isSleepDisabled: Bool {
        if let global {
            return global
        }
        let sources = [battery, charger, ups].compactMap { $0 }
        return !sources.isEmpty && sources.allSatisfy { $0 }
    }
}

public struct PMSetCommand: Equatable {
    public let arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }
}

public enum PMSetSleepStateCodec {
    public static func parseCurrentOutput(
        _ output: String
    ) -> PMSetSleepState {
        for rawLine in output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let fields = rawLine.split(
                whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled",
                  let rawValue = fields.last else {
                continue
            }
            return PMSetSleepState(
                global: rawValue == "1")
        }

        return parseCustomOutput(output)
    }

    public static func parseCustomOutput(_ output: String) -> PMSetSleepState {
        var state = PMSetSleepState()
        var source: WritableKeyPath<PMSetSleepState, Bool?>?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" {
                source = \.battery
            } else if line == "AC Power:" {
                source = \.charger
            } else if line == "UPS Power:" {
                source = \.ups
            } else if line.hasPrefix("disablesleep"),
                      let source,
                      let rawValue = line.split(whereSeparator: \.isWhitespace).last {
                state[keyPath: source] = rawValue == "1"
            }
        }

        if state.battery == nil && output.contains("Battery Power:") {
            state.battery = false
        }
        if state.charger == nil && output.contains("AC Power:") {
            state.charger = false
        }
        if state.ups == nil && output.contains("UPS Power:") {
            state.ups = false
        }
        return state
    }

    public static func restorationCommands(
        for state: PMSetSleepState
    ) -> [PMSetCommand] {
        if let global = state.global {
            return [
                PMSetCommand(
                    arguments: [
                        "-a",
                        "disablesleep",
                        global ? "1" : "0",
                    ])
            ]
        }

        var commands: [PMSetCommand] = []
        if let value = state.battery {
            commands.append(PMSetCommand(
                arguments: ["-b", "disablesleep", value ? "1" : "0"]
            ))
        }
        if let value = state.charger {
            commands.append(PMSetCommand(
                arguments: ["-c", "disablesleep", value ? "1" : "0"]
            ))
        }
        if let value = state.ups {
            commands.append(PMSetCommand(
                arguments: ["-u", "disablesleep", value ? "1" : "0"]
            ))
        }
        if commands.isEmpty {
            commands.append(PMSetCommand(
                arguments: ["-a", "disablesleep", "0"]
            ))
        }
        return commands
    }
}
