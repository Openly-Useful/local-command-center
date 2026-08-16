import Foundation

public struct TextSanitizationLimits: Codable, Equatable, Sendable {
    public let maximumLineBytes: Int
    public let maximumMessageBytes: Int

    public init(maximumLineBytes: Int = 64 * 1_024, maximumMessageBytes: Int = 1_048_576) {
        precondition(maximumLineBytes >= 0)
        precondition(maximumMessageBytes >= 0)
        self.maximumLineBytes = maximumLineBytes
        self.maximumMessageBytes = maximumMessageBytes
    }
}

public struct SanitizedText: Codable, Equatable, Sendable {
    public let text: String
    public let removedControlSequences: Bool
    public let truncatedLineCount: Int
    public let messageWasTruncated: Bool

    public init(
        text: String,
        removedControlSequences: Bool,
        truncatedLineCount: Int,
        messageWasTruncated: Bool
    ) {
        self.text = text
        self.removedControlSequences = removedControlSequences
        self.truncatedLineCount = truncatedLineCount
        self.messageWasTruncated = messageWasTruncated
    }
}

public enum TerminalTextSanitizer {
    private enum ParserState {
        case normal
        case escape
        case escapeIntermediate
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case stringControl
        case stringControlEscape
    }

    public static func sanitize(
        _ input: String,
        limits: TextSanitizationLimits = TextSanitizationLimits()
    ) -> SanitizedText {
        var state = ParserState.normal
        var output = String()
        output.reserveCapacity(min(input.utf8.count, limits.maximumMessageBytes))
        var outputBytes = 0
        var lineBytes = 0
        var currentLineIsTruncated = false
        var truncatedLineCount = 0
        var removedControlSequences = false
        var messageWasTruncated = false

        func recordLineEnd() {
            if currentLineIsTruncated {
                truncatedLineCount += 1
                currentLineIsTruncated = false
            }
            lineBytes = 0
        }

        characterLoop: for character in input {
            let scalars = character.unicodeScalars
            if state == .normal && character == "\r\n" {
                removedControlSequences = true
                guard outputBytes + 1 <= limits.maximumMessageBytes else {
                    messageWasTruncated = true
                    break characterLoop
                }
                output.append("\n")
                outputBytes += 1
                recordLineEnd()
                continue
            }
            let isEntirelyDisplayText = state == .normal && scalars.allSatisfy { scalar in
                let value = scalar.value
                return value == 0x09 || value == 0x0A
                    || (value >= 0x20 && !(0x7F...0x9F).contains(value))
            }

            if isEntirelyDisplayText {
                let characterBytes = character.utf8.count
                guard outputBytes + characterBytes <= limits.maximumMessageBytes else {
                    messageWasTruncated = true
                    break characterLoop
                }

                if character == "\n" {
                    output.append(character)
                    outputBytes += characterBytes
                    recordLineEnd()
                    continue
                }

                guard lineBytes + characterBytes <= limits.maximumLineBytes else {
                    currentLineIsTruncated = true
                    continue
                }
                output.append(character)
                outputBytes += characterBytes
                lineBytes += characterBytes
                continue
            }

            // A Character containing a control scalar is never emitted piecemeal. This keeps
            // truncation and filtering from splitting extended grapheme clusters while the
            // scalar state machine still recognizes terminal protocol delimiters.
            for scalar in scalars {
                let value = scalar.value
                switch state {
                case .normal:
                    removedControlSequences = true
                    switch value {
                    case 0x1B:
                        state = .escape
                    case 0x9B:
                        state = .controlSequence
                    case 0x9D:
                        state = .operatingSystemCommand
                    case 0x90, 0x98, 0x9E, 0x9F:
                        state = .stringControl
                    default:
                        break
                    }

                case .escape:
                    switch value {
                    case 0x5B:
                        state = .controlSequence
                    case 0x5D:
                        state = .operatingSystemCommand
                    case 0x50, 0x58, 0x5E, 0x5F:
                        state = .stringControl
                    case 0x20...0x2F:
                        state = .escapeIntermediate
                    default:
                        state = .normal
                    }

                case .escapeIntermediate:
                    if (0x30...0x7E).contains(value) {
                        state = .normal
                    }

                case .controlSequence:
                    if (0x40...0x7E).contains(value) {
                        state = .normal
                    }

                case .operatingSystemCommand:
                    if value == 0x07 || value == 0x9C {
                        state = .normal
                    } else if value == 0x1B {
                        state = .operatingSystemCommandEscape
                    }

                case .operatingSystemCommandEscape:
                    state = value == 0x5C ? .normal : .operatingSystemCommand

                case .stringControl:
                    if value == 0x9C {
                        state = .normal
                    } else if value == 0x1B {
                        state = .stringControlEscape
                    }

                case .stringControlEscape:
                    state = value == 0x5C ? .normal : .stringControl
                }
            }
        }

        if currentLineIsTruncated {
            truncatedLineCount += 1
        }

        return SanitizedText(
            text: output,
            removedControlSequences: removedControlSequences,
            truncatedLineCount: truncatedLineCount,
            messageWasTruncated: messageWasTruncated
        )
    }
}
