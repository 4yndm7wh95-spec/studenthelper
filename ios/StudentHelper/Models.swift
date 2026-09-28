import Foundation

struct LearningMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String
    var text: String
}

struct LearningChat: Identifiable, Codable {
    var id = UUID()
    var title: String
    var course: String
    var messages: [LearningMessage] = []
    var draft = ""
    var failure: String?
    var waitingQuestion = false
    var reviewDraft = ""
    var reviewStatus: String?
    var replyInProgress = false
    var questionQueue: [QueuedProblem]?
    var questionIndex: Int?
}

struct QueuedProblem: Codable { var number: Int; var text: String }

struct CourseFile: Identifiable, Codable {
    var id = UUID()
    var name: String
    var course: String
    var size: Int64 = 0
    var addedAt = Date()
}

struct LearningState: Codable {
    var courses = ["概率论与数理统计", "高等数学", "线性代数"]
    var selectedCourse = "概率论与数理统计"
    var chats: [LearningChat] = []
    var currentID: UUID?
    var files: [CourseFile] = []
    var subjects: [String: String] = [:]
    var courseNotes: [String: String] = [:]
}

enum Example {
    static let question = "设 0 < P(A) < 1，0 < P(B) < 1，且 P(A | B) + P(A̅ | B̅) = 1，证明 A 与 B 独立。"
    static let answer = "由 P(A̅ | B̅) = 1 − P(A | B̅)，代入条件得 P(A | B) = P(A | B̅) = q。\n由全概率公式，P(A) = qP(B) + qP(B̅) = q。\n因此 P(A | B) = P(A)，A 与 B 独立。"
    static let steps = "① 用互补关系替换题目中的第二项。\n② 整理出两个条件概率相等，记作 q。\n③ 用全概率公式计算 P(A)。\n④ 根据 P(A | B) = P(A) 判断独立。"
    static func chat() -> LearningChat {
        LearningChat(title: "第二章作业 · 条件概率", course: "概率论与数理统计", messages: [
            LearningMessage(role: "user", text: "先做第 24 题。"),
            LearningMessage(role: "paper", text: question),
            LearningMessage(role: "teacher", text: "先看目标：B 是否发生，不影响 A 的概率。\nP(A | B) = P(A)\n这句话能理解吗？")
        ])
    }
}
