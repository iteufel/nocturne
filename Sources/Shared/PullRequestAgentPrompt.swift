import Foundation

public enum PullRequestAgentPrompt {
    public enum Task { case guide, explain, feedback, conflicts }
    public static func make(_ request: PullRequestInfo, files: [GitChange], activity: [PullRequestActivity], task: Task) -> String {
        let instruction: String
        switch task {
        case .guide: instruction = "Write a review guide with a short overview, the important files in review order, code references, risks and validation. Read the actual changes using the local checkout and authenticated forge CLI. Do not edit files, post comments, push or merge."
        case .explain: instruction = "Explain this pull request using the actual changes, file references and validation. Read only: do not edit files, post comments, push or merge."
        case .feedback: instruction = "Read the pull request's feedback and address actionable items in its source checkout. Check the branch first, preserve unrelated edits and ask before switching another checkout. Do not post comments, push or merge."
        case .conflicts: instruction = "Inspect and resolve this pull request's conflicts with its target branch in the correct source checkout. Check the branch and preserve unrelated edits first. Do not push or merge the pull request."
        }
        let context = "Pull request #\(request.number): \(request.title)\nURL: \(request.url)\nSource: \(request.source)\nTarget: \(request.target)\n\nDescription:\n" + request.body + "\n\nChanged files (loaded page):\n" + files.map(\.path).joined(separator: "\n") + "\n\nLoaded feedback:\n" + activity.map { $0.author + ": " + $0.text }.joined(separator: "\n")
        let bytes = Data(context.utf8)
        let preview = String(decoding: bytes.prefix(12_000), as: UTF8.self)
        return instruction + "\n\n" + preview + (bytes.count > 12_000 ? "\n[Context preview truncated; use the PR URL for complete changes and feedback.]" : "")
    }
    public static func summary(_ text: String) -> String? {
        guard let marker = text.range(of: "\n\nPull request #"),
              let line = text[marker.upperBound...].split(separator: "\n").first,
              let number = line.split(separator: ":").first, Int(number) != nil else { return nil }
        let action: String
        if text.hasPrefix("Write a review guide with a short overview") { action = "Write a review guide for" }
        else if text.hasPrefix("Explain this pull request using the actual changes") { action = "Explain" }
        else if text.hasPrefix("Read the pull request's feedback and address actionable items") { action = "Address feedback for" }
        else if text.hasPrefix("Inspect and resolve this pull request's conflicts") { action = "Resolve conflicts for" }
        else { return nil }
        return action + " PR #" + number
    }
}
