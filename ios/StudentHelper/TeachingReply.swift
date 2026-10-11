import Foundation

enum TeachingReply {
    private struct Frame: Decodable {
        let intent: String
        let prerequisite: String
        let prerequisiteReady: Bool
        let action: String
        let focus: String
        let blocks: [String]

        enum CodingKeys: String, CodingKey {
            case intent, prerequisite, action, focus, blocks
            case prerequisiteReady = "prerequisite_ready"
        }
    }

    static func decode(_ content: String) throws -> String {
        guard let data = content.data(using: .utf8), let frame = try? JSONDecoder().decode(Frame.self, from: data) else {
            throw ModelConnectionError.teachingReply
        }
        let actions = ["name", "meaning", "reason", "check", "step", "complete"]
        let intents = ["opening", "local", "continue", "attempt", "full"]
        let blocks = frame.blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard actions.contains(frame.action), intents.contains(frame.intent),
              !frame.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              frame.focus.utf16.count <= 120,
              !blocks.isEmpty, blocks.count <= 64, blocks.allSatisfy({ !$0.isEmpty }),
              (frame.action == "complete") == (frame.intent == "full"),
              frame.prerequisiteReady || !frame.prerequisite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelConnectionError.teachingReply
        }
        let text = blocks.joined(separator: "\n\n")
        if frame.action != "complete" {
            guard blocks.count <= 4, chineseCount(text) <= 120,
                  blocks.allSatisfy({ chineseCount($0) <= 60 }) else {
                throw ModelConnectionError.teachingReply
            }
        }
        return text
    }

    private static func chineseCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
    }
}
