/// What the system reported, gathered by the app (FSKit and the bundle) and evaluated here, where it is tested.
public struct SystemFacts: Sendable, Equatable {
    /// Where the running app is installed.
    public let appPath: String
    /// Every file system module FSKit knows: bundle identifier → enabled.
    public let modules: [String: Bool]
    /// Why FSKit could not be asked, when it could not.
    public let queryFailure: String?

    public init(appPath: String, modules: [String: Bool], queryFailure: String?) {
        self.appPath = appPath
        self.modules = modules
        self.queryFailure = queryFailure
    }
}
