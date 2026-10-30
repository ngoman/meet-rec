import Foundation
import Testing
@testable import MeetRecCore

private func tempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-\(UUID().uuidString.prefix(8))-\(name)")
}

private func releaseJSON(tag: String = "v1.2.3", draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]) -> Data {
    let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
    return Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list)]}"#.utf8)
}

private let base = "https://github.com/ngoman/meet-rec/releases/download/v1.2.3/"

extension AllTests {
    @Suite struct UpdaterTests {
        @Test func parsesVersions() throws {
            #expect(AppVersion("v1.2.3")?.description == "1.2.3")
            #expect(AppVersion("1.2")?.description == "1.2.0")
            #expect(AppVersion("7")?.description == "7.0.0")
            #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
            #expect(AppVersion("1.2.3")! == AppVersion("v1.2.3")!)
            #expect(AppVersion("0.0.0")! < AppVersion("0.0.1")!)
            for junk in ["", "v", "1.2.3.4", "1..2", "1.2.x", "1.2.3-beta", "abc", " 1.2", "-1.2", "1.2.3 ", "99999999999999999999"] {
                #expect(AppVersion(junk) == nil, "\(junk)")
            }
        }

        @Test func picksAssetsForArch() throws {
            let data = releaseJSON(assets: [
                ("MeetRec-x86_64.zip", base + "MeetRec-x86_64.zip"), ("MeetRec-arm64.zip", base + "MeetRec-arm64.zip"),
                ("MeetRec-arm64.zip.sha256", base + "MeetRec-arm64.zip.sha256"),
            ])
            let release = try #require(try Updater.parseRelease(data: data, arch: "arm64", requireGitHub: true))
            #expect(release.version == "1.2.3")
            #expect(release.archiveURL.absoluteString == base + "MeetRec-arm64.zip")
            #expect(release.checksumURL.absoluteString == base + "MeetRec-arm64.zip.sha256")
            #expect(try Updater.parseRelease(data: data, arch: "x86_64", requireGitHub: true) == nil)
            #expect(try Updater.parseRelease(data: releaseJSON(tag: "1.5", assets: []), arch: "arm64", requireGitHub: true) == nil)
            #expect(try Updater.parseRelease(data: releaseJSON(tag: "nightly", assets: []), arch: "arm64", requireGitHub: true) == nil)
        }

        @Test func rejectsForeignHostAndSkipsDraft() throws {
            let foreign = releaseJSON(assets: [
                ("MeetRec-arm64.zip", "https://evil.example/MeetRec-arm64.zip"), ("MeetRec-arm64.zip.sha256", base + "MeetRec-arm64.zip.sha256"),
            ])
            #expect(throws: MeetRecError.self) { try Updater.parseRelease(data: foreign, arch: "arm64", requireGitHub: true) }
            #expect(try Updater.parseRelease(data: foreign, arch: "arm64", requireGitHub: false) != nil)
            let assets = [("MeetRec-arm64.zip", base + "MeetRec-arm64.zip"), ("MeetRec-arm64.zip.sha256", base + "MeetRec-arm64.zip.sha256")]
            #expect(try Updater.parseRelease(data: releaseJSON(draft: true, assets: assets), arch: "arm64", requireGitHub: true) == nil)
            #expect(try Updater.parseRelease(data: releaseJSON(prerelease: true, assets: assets), arch: "arm64", requireGitHub: true) == nil)
            #expect(throws: MeetRecError.self) { try Updater.parseRelease(data: Data("[]".utf8), arch: "arm64", requireGitHub: true) }
        }

        @Test func checkDueBoundaries() {
            let now = Date()
            #expect(UpdatePolicy.isCheckDue(lastCheck: nil, now: now))
            #expect(!UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-86399), now: now))
            #expect(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-86400), now: now))
            #expect(!UpdatePolicy.isCheckDue(lastCheck: now, now: now))
            #expect(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(60), now: now))
        }

        @Test func installDecision() {
            #expect(UpdatePolicy.shouldInstall(candidate: "1.2.0", current: "1.1.9", failedVersion: nil, manual: false))
            #expect(!UpdatePolicy.shouldInstall(candidate: "1.2.0", current: "1.2.0", failedVersion: nil, manual: true))
            #expect(!UpdatePolicy.shouldInstall(candidate: "1.1.0", current: "1.2.0", failedVersion: nil, manual: true))
            #expect(!UpdatePolicy.shouldInstall(candidate: "1.2.0", current: "1.1.0", failedVersion: "1.2.0", manual: false))
            #expect(UpdatePolicy.shouldInstall(candidate: "1.2.0", current: "1.1.0", failedVersion: "1.2.0", manual: true))
            #expect(UpdatePolicy.shouldInstall(candidate: "1.3.0", current: "1.1.0", failedVersion: "1.2.0", manual: false))
            #expect(!UpdatePolicy.shouldInstall(candidate: "junk", current: "1.1.0", failedVersion: nil, manual: true))
        }

        @Test func updateStateRoundTrip() throws {
            let url = tempURL("state/update-state.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(UpdateState.load(from: url) == UpdateState())
            let state = UpdateState(
                lastCheck: Date(timeIntervalSince1970: 1_800_000_000), failedVersion: "1.2.0",
                lastResult: UpdateResult(from: "1.1.0", to: "1.2.0", ok: false, error: "x"))
            try state.save(to: url)
            #expect(UpdateState.load(from: url) == state)
            try "{broken".write(to: url, atomically: true, encoding: .utf8)
            #expect(UpdateState.load(from: url) == UpdateState())
        }

        @Test func restartConditions() {
            #expect(UpdatePolicy.canRestart(idle: 0, sinceWork: nil, explicit: true))
            #expect(!UpdatePolicy.canRestart(idle: 0, sinceWork: 119, explicit: true))
            #expect(UpdatePolicy.canRestart(idle: 0, sinceWork: 120, explicit: true))
            #expect(!UpdatePolicy.canRestart(idle: 119, sinceWork: nil, explicit: false))
            #expect(UpdatePolicy.canRestart(idle: 120, sinceWork: nil, explicit: false))
            #expect(!UpdatePolicy.canRestart(idle: 500, sinceWork: 119, explicit: false))
            #expect(UpdatePolicy.canRestart(idle: 500, sinceWork: 120, explicit: false))
        }

        @Test func stateUpdateKeepsOtherFields() throws {
            let url = tempURL("state/update-state.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            UpdateState.update(at: url) { $0.failedVersion = "1.2.0" }
            UpdateState.update(at: url) { $0.lastCheck = Date(timeIntervalSince1970: 1_800_000_000) }
            let state = UpdateState.load(from: url)
            #expect(state.failedVersion == "1.2.0" && state.lastCheck != nil)
        }

        @Test func feedOverrideAcceptsOnlyLocal() {
            defer { unsetenv("MEETREC_UPDATE_FEED") }
            setenv("MEETREC_UPDATE_FEED", "file:///tmp/feed.json", 1)
            #expect(Updater.feedOverride != nil)
            setenv("MEETREC_UPDATE_FEED", "http://127.0.0.1:8000/feed", 1)
            #expect(Updater.feedOverride != nil)
            setenv("MEETREC_UPDATE_FEED", "http://example.com/feed", 1)
            #expect(Updater.feedOverride == nil)
            setenv("MEETREC_UPDATE_FEED", "https://localhost/feed", 1)
            #expect(Updater.feedOverride == nil)
            #expect(Updater.feedURL.host == "api.github.com")
        }

        @Test func autoUpdateConfig() throws {
            var config = Config()
            #expect(config.autoUpdate)
            try config.set(key: "autoUpdate", value: "off")
            #expect(!config.autoUpdate)
            try config.set(key: "autoUpdate", value: "true")
            #expect(config.autoUpdate)
            #expect(throws: MeetRecError.self) { try config.set(key: "autoUpdate", value: "maybe") }
            #expect(Config.keys.contains("autoUpdate"))
            let support = tempURL("cfg")
            setenv("MEETREC_SUPPORT_DIR", support.path, 1)
            defer {
                unsetenv("MEETREC_SUPPORT_DIR")
                try? FileManager.default.removeItem(at: support)
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(#"{"language":"en"}"#.utf8).write(to: support.appendingPathComponent("config.json"))
            let loaded = try Config.load()
            #expect(loaded.autoUpdate && loaded.language == "en")
            try Data(#"{"autoUpdate":false}"#.utf8).write(to: support.appendingPathComponent("config.json"))
            #expect(!(try Config.load().autoUpdate))
        }

        @Test func controlResponseUpdateFields() throws {
            var response = ControlResponse()
            response.version = "1.2.3"
            response.updateStatus = "Проверяю обновления…"
            response.updateAvailable = "1.3.0"
            let back = try ControlCodec.decode(ControlResponse.self, from: try ControlCodec.encode(response).dropLast())
            #expect(back == response)
            let old = try ControlCodec.decode(ControlResponse.self, from: Data(#"{"ok":true}"#.utf8))
            #expect(old.version == nil && old.updateStatus == nil && old.updateAvailable == nil)
        }
    }

    @Suite struct UpdateInstallerTests {
        struct Fixture {
            let root: URL
            let installed: URL
            let staged: URL
            let backup: URL
            let state: URL
            var installer = UpdateInstaller()
            let launches = Counter()
            let resultAtLaunch = Counter()

            init() throws {
                root = tempURL("apply")
                installed = root.appendingPathComponent("MeetRec.app")
                staged = root.appendingPathComponent("updates/staged/MeetRec.app")
                backup = root.appendingPathComponent("update-rollback/MeetRec.app")
                state = root.appendingPathComponent("update-state.json")
                let fm = FileManager.default
                try fm.createDirectory(at: installed, withIntermediateDirectories: true)
                try fm.createDirectory(at: staged, withIntermediateDirectories: true)
                try "old".write(to: installed.appendingPathComponent("v"), atomically: true, encoding: .utf8)
                try "new".write(to: staged.appendingPathComponent("v"), atomically: true, encoding: .utf8)
                installer.stateURL = state
                installer.backup = backup
                installer.exitWait = 0.1
                installer.exitGiveUp = 0.4
                installer.probeTimeout = 0.3
                installer.probeInterval = 0.02
                installer.isAlive = { _ in false }
                installer.register = { _ in }
                installer.terminateNew = { _ in }
                installer.sessionBusy = { false }
                installer.isNewRunning = { _ in false }
                installer.busyWait = 0.3
                installer.busyInterval = 0.02
                installer.log = { _ in }
                let launches = launches, resultAtLaunch = resultAtLaunch, state = state, root = root
                installer.launch = {
                    launches.append((try? String(contentsOf: $0.appendingPathComponent("v"), encoding: .utf8)) ?? "?")
                    resultAtLaunch.append(UpdateState.load(from: state).lastResult == nil ? "none" : "recorded")
                    try? FileManager.default.removeItem(at: root.appendingPathComponent("updates"))
                }
            }

            func content(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("v"), encoding: .utf8) }
            func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
            func cleanup() { try? FileManager.default.removeItem(at: root) }
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }

        @Test func succeeds() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.probe = { "2.0.0" }
            #expect(f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "new")
            #expect(!f.exists(f.staged) && !f.exists(f.backup))
            #expect(f.launches.all == ["new"])
            let state = UpdateState.load(from: f.state)
            #expect(state.lastResult == UpdateResult(from: "1.0.0", to: "2.0.0", ok: true) && state.failedVersion == nil)
        }

        @Test func rollsBackAfterNewVersionWipesUpdates() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.probe = { "1.0.0" }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old")
            #expect(!f.exists(f.backup))
            #expect(f.launches.all == ["new", "old"])
            #expect(f.resultAtLaunch.all == ["none", "recorded"])
            let state = UpdateState.load(from: f.state)
            #expect(state.failedVersion == "2.0.0" && state.lastResult?.ok == false && state.lastResult?.error != nil)
        }

        @Test func waitTimeoutSkipsSwap() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.isAlive = { kill($0, 0) == 0 }
            f.installer.probe = { "2.0.0" }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: getpid(), from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old" && f.content(f.staged) == "new")
            #expect(f.launches.all.isEmpty)
            let state = UpdateState.load(from: f.state)
            #expect(state.lastResult?.ok == false && state.failedVersion == nil)
        }

        @Test func lateExitLaunchesOldWithoutSwap() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            let started = Date()
            f.installer.isAlive = { _ in Date().timeIntervalSince(started) < 0.25 }
            f.installer.probe = { "2.0.0" }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old" && !f.exists(f.backup))
            #expect(f.launches.all == ["old"])
            #expect(UpdateState.load(from: f.state).lastResult?.ok == false)
        }

        @Test func swapFailureLaunchesOldVersion() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.staged)
            f.installer.probe = { "2.0.0" }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old")
            #expect(f.launches.all == ["old"])
            #expect(f.resultAtLaunch.all == ["recorded"])
            let state = UpdateState.load(from: f.state)
            #expect(state.failedVersion == nil && state.lastResult?.ok == false)
        }

        @Test func busyWithLiveNewVersionBlocksRollbackUntilExpiry() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.probe = { nil }
            f.installer.sessionBusy = { true }
            f.installer.isNewRunning = { _ in true }
            f.installer.terminateNew = { _ in Issue.record("must not terminate") }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "new" && f.content(f.backup) == "old")
            #expect(f.launches.all == ["new"])
            let state = UpdateState.load(from: f.state)
            #expect(state.failedVersion == nil && state.lastResult?.ok == false)
        }

        @Test func crashedNewVersionRollsBackDespiteBusySession() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.probe = { nil }
            f.installer.sessionBusy = { true }
            f.installer.isNewRunning = { _ in false }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old")
            #expect(f.launches.all == ["new", "old"])
            #expect(!f.exists(f.backup.deletingLastPathComponent()))
        }

        @Test func rollsBackAfterBusySessionIsFreed() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            f.installer.probe = { nil }
            f.installer.busyWait = 5
            let polls = Counter()
            let freedAt = Counter()
            f.installer.sessionBusy = {
                polls.append("x")
                return polls.all.count < 4
            }
            let launches = f.launches
            f.installer.terminateNew = { _ in freedAt.append("\(polls.all.count)/\(launches.all.count)") }
            f.installer.isNewRunning = { _ in true }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "old")
            #expect(freedAt.all == ["5/1"])
            #expect(f.launches.all == ["new", "old"])
        }

        @Test func lateAnswerDuringBusyWaitKeepsNewVersion() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            let polls = Counter()
            f.installer.busyWait = 5
            f.installer.sessionBusy = {
                polls.append("x")
                return true
            }
            f.installer.probe = { polls.all.count >= 2 ? "2.0.0" : nil }
            f.installer.isNewRunning = { _ in true }
            f.installer.terminateNew = { _ in Issue.record("must not terminate") }
            #expect(f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(f.content(f.installed) == "new" && !f.exists(f.backup))
            #expect(f.launches.all == ["new"])
            let state = UpdateState.load(from: f.state)
            #expect(state.failedVersion == nil && state.lastResult?.ok == true)
        }

        @Test func needsTwoFreePollsInARow() throws {
            var f = try Fixture()
            defer { f.cleanup() }
            let polls = Counter()
            let terminatedAt = Counter()
            let pattern = [true, false, true, false, false]
            f.installer.busyWait = 5
            f.installer.probe = { nil }
            f.installer.sessionBusy = {
                polls.append("x")
                return pattern[min(polls.all.count, pattern.count) - 1]
            }
            f.installer.isNewRunning = { _ in true }
            f.installer.terminateNew = { _ in terminatedAt.append("\(polls.all.count)") }
            #expect(!f.installer.apply(staged: f.staged, installed: f.installed, pid: 1, from: "1.0.0", to: "2.0.0"))
            #expect(terminatedAt.all == ["5"])
            #expect(f.content(f.installed) == "old")
        }
    }
}
