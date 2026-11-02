import AppSupport

extension AutomationResult {
    /// What an `--unmount` launch's result says went wrong: nothing when it is done.
    static func unmountProblems(_ result: AutomationResult?) -> [String] {
        switch result {
            case .done?: []
            case .failed(let text)?: ["unmount: \(text)"]
            case .mounted?: ["unmount: MacFS answered with a mount"]
            case nil: ["unmount: MacFS gave no result"]
        }
    }
}
