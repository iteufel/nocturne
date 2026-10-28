import Foundation
import NocturneKit

/// Deliberately supports bounded, non-secret, fixed-choice questions only.
/// Option labels are provider answers, not inferred grant/deny semantics.
enum CodexAttentionQuestions {
    struct Question {
        let id: String
        let title: String
        let detail: String
        let options: [ChatPermissionOption]
        let labels: [String: String]
    }
    static func parse(_ params: [String: Any]) throws -> [Question] {
        guard let rows = params["questions"] as? [[String: Any]], (1...3).contains(rows.count) else { throw NocturneError.invalidFrame }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                  row["isSecret"] as? Bool != true, row["isOther"] as? Bool != true,
                  let title = row["header"] as? String, let text = row["question"] as? String,
                  let choices = row["options"] as? [[String: Any]], (1...8).contains(choices.count) else { throw NocturneError.invalidFrame }
            var labels: [String: String] = [:], options: [ChatPermissionOption] = [], details = [text]
            for (index, choice) in choices.enumerated() {
                guard let label = choice["label"] as? String, !label.isEmpty, label.utf8.count <= 1024,
                      !labels.values.contains(label), let description = choice["description"] as? String else { throw NocturneError.invalidFrame }
                let option = String(index)
                labels[option] = label; options.append(ChatPermissionOption(id: option, title: label))
                details.append(label + ": " + description)
            }
            let detail = details.joined(separator: "\n\n")
            guard title.utf8.count <= 1024, detail.utf8.count <= 16_384 else { throw NocturneError.invalidFrame }
            return Question(id: id, title: title, detail: detail, options: options, labels: labels)
        }
    }
}
