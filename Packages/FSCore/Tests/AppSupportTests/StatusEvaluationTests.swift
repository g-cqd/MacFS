import AppSupport
import Formats
import Testing

/// What the app's status pane says, from what the system reports (FSKit's module list, where the app is installed).
@Suite struct StatusEvaluationTests {
    static let everyModule = Dictionary(
        uniqueKeysWithValues: DiskFormat.allCases.map { ($0.moduleBundleIdentifier, true) })

    static func facts(
        path: String = "/Applications/MacFS.app", modules: [String: Bool]? = everyModule, failure: String? = nil
    )
        -> SystemFacts
    {
        SystemFacts(appPath: path, modules: modules ?? [:], queryFailure: failure)
    }

    @Test func everythingInPlaceIsReady() {
        let checks = StatusEvaluation.checks(Self.facts())
        #expect(checks.allSatisfy { $0.state == .ok || $0.state == .information })
        #expect(StatusEvaluation.summary(checks).state == .ok)
        #expect(checks.filter { $0.id.hasPrefix("module.") }.count == DiskFormat.allCases.count)
    }

    @Test func outsideApplicationsTheModulesCannotRegister() {
        let checks = StatusEvaluation.checks(Self.facts(path: "/Users/someone/Downloads/MacFS.app", modules: [:]))
        let location = checks.first { $0.id == "app.location" }
        #expect(location?.state == .attention)
        #expect(location?.remedy == .moveToApplications)
        for format in DiskFormat.allCases {
            let module = checks.first { $0.id == "module.\(format.rawValue)" }
            #expect(module?.state == .failed)
            #expect(module?.remedy == .moveToApplications, "a module is missing because of where the app is")
        }
        #expect(StatusEvaluation.summary(checks).state == .failed)
    }

    @Test func aDisabledModuleAsksToBeEnabled() {
        var modules = Self.everyModule
        modules[DiskFormat.ext.moduleBundleIdentifier] = false
        let checks = StatusEvaluation.checks(Self.facts(modules: modules))
        let ext = checks.first { $0.id == "module.ext" }
        #expect(ext?.state == .attention)
        #expect(ext?.remedy == .openExtensionSettings)
        #expect(StatusEvaluation.summary(checks).state == .attention)
        #expect(StatusEvaluation.summary(checks).headline.contains("1"))
    }

    @Test func aMissingModuleInPlaceAsksForAReinstall() {
        var modules = Self.everyModule
        modules[DiskFormat.btrfs.moduleBundleIdentifier] = nil
        let btrfs = StatusEvaluation.checks(Self.facts(modules: modules)).first { $0.id == "module.btrfs" }
        #expect(btrfs?.state == .failed)
        #expect(btrfs?.remedy == .reinstall)
    }

    @Test func whenFSKitDoesNotAnswerNothingIsClaimed() {
        let checks = StatusEvaluation.checks(Self.facts(modules: [:], failure: "XPC interrupted"))
        let query = checks.first { $0.id == "fskit.query" }
        #expect(query?.state == .failed)
        #expect(query?.detail.contains("XPC interrupted") == true)
        #expect(checks.filter { $0.id.hasPrefix("module.") }.allSatisfy { $0.state == .unknown })
    }

    @Test func modulesOfOtherAppsAreIgnored() {
        var modules = Self.everyModule
        modules["com.example.OtherFS"] = false
        #expect(StatusEvaluation.summary(StatusEvaluation.checks(Self.facts(modules: modules))).state == .ok)
    }

    /// macOS's own read-only NTFS driver claims NTFS volumes before any module: the pane says so (research
    /// 2026-10-30-fskit-requirements).
    @Test func theNTFSNoteNamesTheSystemDriver() {
        let note = StatusEvaluation.checks(Self.facts()).first { $0.id == "note.ntfs" }
        #expect(note?.state == .information)
        #expect(note?.detail.contains(DiskFormat.ntfs.shortName) == true)
    }

    @Test func theReportIsPlainText() {
        let report = StatusEvaluation.report(StatusEvaluation.checks(Self.facts()), facts: Self.facts())
        #expect(report.contains("/Applications/MacFS.app"))
        for format in DiskFormat.allCases { #expect(report.contains(format.moduleBundleIdentifier)) }
    }
}
