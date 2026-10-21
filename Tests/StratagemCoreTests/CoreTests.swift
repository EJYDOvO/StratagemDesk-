import XCTest
import CryptoKit
@testable import StratagemCore

final class CoreTests: XCTestCase {
    func testWindowsImportDiscardsForeignSettingsBeforeValidation() throws {
        var action = ActionDefinition(); action.approved = true
        var entry = item([.up]); entry.steps = [WorkflowStep(actionID: action.id)]
        var config = Configuration(); config.custom = [entry]; config.actions = [action]
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        document["platform"] = "windows"
        document["settings"] = ["hotkeyPlatform": "windows", "hotkeyCode": 83, "hotkeyModifiers": 3, "exactLeftShift": false]
        var settings = AppSettings(); settings.inputTimeout = 12
        let imported = try ConfigurationStore.quarantinedImport(JSONSerialization.data(withJSONObject: document), preserving: settings)
        XCTAssertEqual(imported.settings, settings)
        XCTAssertFalse(imported.custom[0].enabled); XCTAssertTrue(imported.custom[0].confirmation)
        XCTAssertFalse(imported.actions[0].approved)
    }
    func testBuiltinIDCollisionRejectedOnImportLoadAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        try store.save(Configuration()); let before = try Data(contentsOf: store.url)
        var custom = Stratagem(); custom.id = try XCTUnwrap(BuiltinCatalog.load().first?.id)
        var invalid = Configuration(); invalid.custom = [custom]
        let bytes = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(try ConfigurationStore.decode(bytes))
        XCTAssertThrowsError(try ConfigurationStore.quarantinedImport(bytes, preserving: AppSettings()))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }
    func testActivationKeysCannotShadowWorkflowInput() throws {
        for key: UInt32 in [36, 53, 76, 123, 124, 125, 126] {
            var config = Configuration(); config.settings.hotkeyCode = key
            XCTAssertThrowsError(try ConfigurationStore.validate(config))
        }
        var exact = Configuration(); exact.settings.hotkeyCode = 48; exact.settings.hotkeyModifiers = 512
        XCTAssertNoThrow(try ConfigurationStore.validate(exact))
    }
    func testProfileComparisonIncludesActionsButIgnoresGeneratedIDs() throws {
        var action = ActionDefinition(); action.target = "printf original"; action.approved = true
        var entry = item([.up]); entry.steps = [WorkflowStep(actionID: action.id)]
        var config = Configuration(); config.custom = [entry]; config.actions = [action]
        let profile = try XCTUnwrap(config.profile(for: entry.id, builtins: []))
        var copy = profile; copy.actions[0].id = "new-action"
        copy.entry.steps[0].id = "new-step"; copy.entry.steps[0].actionID = "new-action"
        XCTAssertTrue(profile.equivalent(to: copy))
        copy.actions[0].target = "printf edited"
        XCTAssertFalse(profile.equivalent(to: copy))
        copy.actions[0].target = action.target; copy.actions[0].approved = false
        XCTAssertFalse(profile.equivalent(to: copy))
        copy = profile; copy.entry.enabled = false
        XCTAssertFalse(profile.equivalent(to: copy))
    }
    func testApplyingProfileSeparatesSharedActionsAndPreservesOtherEntry() throws {
        var action = ActionDefinition(); action.target = "printf original"; action.approved = true
        var first = item([.up]), second = item([.down])
        first.steps = [WorkflowStep(actionID: action.id)]; second.steps = [WorkflowStep(actionID: action.id)]
        var config = Configuration(); config.custom = [first, second]; config.actions = [action]
        let otherBefore = try XCTUnwrap(config.profile(for: second.id, builtins: []))
        var edited = try XCTUnwrap(config.profile(for: first.id, builtins: []))
        edited.actions[0].target = "printf revised"; edited.actions[0].approved = false
        config.apply(edited, builtins: [])
        let after = try XCTUnwrap(config.profile(for: first.id, builtins: []))
        XCTAssertTrue(after.equivalent(to: edited))
        XCTAssertNotEqual(after.entry.steps[0].actionID, action.id)
        XCTAssertEqual(config.profile(for: second.id, builtins: []), otherBefore)
        XCTAssertEqual(config.action(action.id), action)
        try ConfigurationStore.validate(config)
        config.apply(StratagemProfile(entry: first, actions: [action]), builtins: [])
        XCTAssertEqual(config.actions, [action])
    }
    func testSingleProfileSaveAndReloadLeavesOtherDraftAndSettingsOut() throws {
        var action = ActionDefinition(); action.target = "printf saved"
        var first = item([.up]), second = item([.down])
        first.steps = [WorkflowStep(actionID: action.id)]; second.steps = first.steps
        var saved = Configuration(); saved.custom = [first, second]; saved.actions = [action]
        var draft = saved; draft.custom[0].name = "save me"; draft.custom[1].name = "keep editing"
        draft.settings.inputTimeout = 17
        var profile = try XCTUnwrap(draft.profile(for: first.id, builtins: [])); profile.actions[0].target = "printf changed"
        draft.apply(profile, builtins: [])
        saved.apply(try XCTUnwrap(draft.profile(for: first.id, builtins: [])), builtins: [])
        XCTAssertEqual(saved.custom[1], second)
        XCTAssertEqual(saved.settings, AppSettings())
        XCTAssertEqual(draft.custom[1].name, "keep editing")
        XCTAssertEqual(draft.settings.inputTimeout, 17)
        let decoded = try ConfigurationStore.decode(JSONEncoder().encode(saved))
        XCTAssertTrue(try XCTUnwrap(decoded.profile(for: first.id, builtins: [])).equivalent(to: profile))
        XCTAssertEqual(decoded.profile(for: second.id, builtins: [])?.actions, [action])
    }
    func testRestoreBuiltinDefaultIncludesActionsAndLeavesOtherProfilesAlone() throws {
        let builtins = try BuiltinCatalog.load(), defaults = BuiltinCatalog.defaults(builtins: try BuiltinCatalog.load())
        let id = "desk.workflow"
        let original = try XCTUnwrap(defaults.profile(for: id, builtins: builtins))
        XCTAssertFalse(original.entry.enabled); XCTAssertTrue(original.actions.allSatisfy { !$0.approved })
        var changed = defaults
        var profile = original; profile.entry.enabled = true; profile.actions[0].target = "printf custom"; profile.actions[0].approved = true
        changed.apply(profile, builtins: builtins)
        let other = changed.profile(for: "desk.terminal", builtins: builtins)
        changed.apply(original, builtins: builtins)
        XCTAssertTrue(try XCTUnwrap(changed.profile(for: id, builtins: builtins)).equivalent(to: original))
        XCTAssertEqual(changed.profile(for: "desk.terminal", builtins: builtins), other)
    }
    func testProfileMergeRetainsConflictAndSensitiveExportChecks() throws {
        var action = ActionDefinition(); action.sensitive = true; action.target = "PROFILE_SECRET"
        var first = item([.up]), second = item([.down]); first.steps = [WorkflowStep(actionID: action.id)]
        var saved = Configuration(); saved.custom = [first, second]; saved.actions = [action]
        second.sequence = [.up, .right]
        saved.apply(StratagemProfile(entry: second, actions: []), builtins: [])
        XCTAssertFalse(SequenceMatcher.conflicts(in: saved.resolved(builtins: [])).isEmpty)
        let exported = try ConfigurationStore.exportData(saved)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PROFILE_SECRET"))
        var blank = Stratagem(); blank.id = first.id
        saved.apply(StratagemProfile(entry: blank, actions: []), builtins: [])
        XCTAssertTrue(saved.actions.isEmpty)
        XCTAssertTrue(saved.profile(for: first.id, builtins: [])?.actions.isEmpty == true)
    }
    func testBundledArtworkIsCompleteAndMatchesSourceHashes() throws {
        let directory = try XCTUnwrap(BundledArtwork.directory)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("index.json"))) as? [String: [String: String]])
        let sources = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("sources.json"))) as? [String: Any])
        let entries = try XCTUnwrap(sources["entries"] as? [[String: String]])
        let builtins = try BuiltinCatalog.load()
        XCTAssertEqual(Set(entries.compactMap { $0["id"] }), Set(builtins.map(\.id)))
        XCTAssertEqual(index["icons"]?.count, builtins.count)
        for entry in entries {
            let id = try XCTUnwrap(entry["id"]), filename = try XCTUnwrap(entry["file"])
            XCTAssertEqual(filename, URL(fileURLWithPath: filename).lastPathComponent)
            XCTAssertEqual(index["icons"]?[id], filename)
            XCTAssertEqual(index["defaultIcons"]?[id], builtins.first { $0.id == id }?.icon)
            let data = try Data(contentsOf: directory.appendingPathComponent(filename))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry["sha256"])
        }
    }
    func testBulkEnablePreservesMappingsAndApprovalsAcrossEntryKinds() throws {
        var builtin = Stratagem(); builtin.id = "builtin"; builtin.sequence = [.up]
        var overridden = Stratagem(); overridden.id = "overridden"; overridden.sequence = [.down]
        var customized = overridden; customized.name = "edited"; customized.confirmation = false
        var orphan = Stratagem(); orphan.id = "orphan"; orphan.sequence = [.left]
        var custom = Stratagem(); custom.id = "custom"; custom.sequence = [.right]
        var untouched = Stratagem(); untouched.id = "untouched"; untouched.sequence = [.up, .right]
        var action = ActionDefinition(); action.target = "printf test"; action.approved = false
        custom.steps = [WorkflowStep(actionID: action.id)]
        var config = Configuration(); config.actions = [action]
        config.overrides = [customized.id: customized, orphan.id: orphan]; config.custom = [custom, untouched]
        let before = config
        let ids: Set<String> = [builtin.id, customized.id, orphan.id, custom.id, "deleted"]
        XCTAssertEqual(config.setEnabled(true, for: ids, builtins: [builtin, overridden]), 4)
        let entries = config.resolved(builtins: [builtin, overridden])
        XCTAssertTrue(entries.filter { ids.contains($0.id) }.allSatisfy(\.enabled))
        XCTAssertEqual(entries.first { $0.id == untouched.id }, untouched)
        XCTAssertEqual(config.actions, before.actions)
        XCTAssertEqual(config.settings, before.settings)
        XCTAssertEqual(config.overrides[customized.id]?.name, "edited")
        XCTAssertEqual(config.overrides[customized.id]?.confirmation, false)
        XCTAssertEqual(config.custom.first?.steps, custom.steps)
        let decoded = try ConfigurationStore.decode(JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(config.setEnabled(true, for: ids, builtins: [builtin, overridden]), 0)
        XCTAssertEqual(config.setEnabled(false, for: ids, builtins: [builtin, overridden]), 4)
        XCTAssertEqual(config.resolved(builtins: [builtin, overridden]), before.resolved(builtins: [builtin, overridden]))
    }
    func testBulkSelectionDoesNotBypassConflictsAndCanResolveThem() {
        let first = item([.up], enabled: false), second = item([.up, .down], enabled: false)
        var config = Configuration(); config.custom = [first, second]
        XCTAssertEqual(config.setEnabled(true, for: [], builtins: []), 0)
        XCTAssertEqual(config.setEnabled(true, for: [first.id, second.id], builtins: []), 2)
        XCTAssertFalse(SequenceMatcher.conflicts(in: config.resolved(builtins: [])).isEmpty)
        XCTAssertEqual(config.setEnabled(false, for: [second.id], builtins: []), 1)
        XCTAssertTrue(SequenceMatcher.conflicts(in: config.resolved(builtins: [])).isEmpty)
        XCTAssertTrue(config.custom[0].enabled)
    }
    func item(_ sequence: [Direction], enabled: Bool = true) -> Stratagem {
        var s = Stratagem(); s.sequence = sequence; s.enabled = enabled; return s
    }
    func testExactAndPrefixMatch() {
        let s = item([.up, .down, .right])
        XCTAssertEqual(SequenceMatcher.match([.up], in: [s]), .waiting([s.id]))
        XCTAssertEqual(SequenceMatcher.match(s.sequence, in: [s]), .matched(s.id))
        XCTAssertEqual(SequenceMatcher.match([.left], in: [s]), .invalid)
    }
    func testDisabledIsNeverMatched() { XCTAssertEqual(SequenceMatcher.match([.up], in: [item([.up], enabled: false)]), .invalid) }
    func testPrefixCollisionBlocksMatch() {
        let entries = [item([.up]), item([.up, .down])]
        XCTAssertEqual(SequenceMatcher.conflicts(in: entries).count, 1)
        XCTAssertEqual(SequenceMatcher.match([.up], in: entries), .ambiguous)
    }
    func testDuplicateCollision() { XCTAssertEqual(SequenceMatcher.conflicts(in: [item([.right]), item([.right])]).count, 1) }
    func testEmptyActiveSequenceRejected() { XCTAssertFalse(SequenceMatcher.conflicts(in: [item([])]).isEmpty) }
    func testCatalogAndDefaultsAreSafe() throws {
        let builtins = try BuiltinCatalog.load()
        XCTAssertEqual(builtins.count, 8)
        XCTAssertEqual(Set(builtins.map(\.id)).count, builtins.count)
        XCTAssertTrue(builtins.allSatisfy { !$0.enabled && !$0.sequence.isEmpty && !$0.icon.contains("http") })
        let defaults = BuiltinCatalog.defaults(builtins: builtins)
        try ConfigurationStore.validate(defaults)
        XCTAssertEqual(defaults.overrides.count, builtins.count)
        XCTAssertTrue(defaults.actions.allSatisfy { !$0.approved })
        XCTAssertTrue(defaults.resolved(builtins: builtins).allSatisfy { !$0.enabled })
    }
    func testOverrideSurvivesBuiltinUpdate() {
        var original = item([.up]); original.name = "old"
        var custom = original; custom.name = "my override"; custom.sequence = [.right]
        var config = Configuration(); config.overrides[original.id] = custom
        original.name = "new upstream"
        XCTAssertEqual(config.resolved(builtins: [original]), [custom])
        XCTAssertEqual(config.resolved(builtins: []), [custom])
    }
    func testImportRevokesEveryApprovalAndKeepsSettings() throws {
        var a = ActionDefinition(); a.approved = true
        var s = item([.up]); s.confirmation = false; s.steps = [WorkflowStep(actionID: a.id)]
        var c = Configuration(); c.actions = [a]; c.custom = [s]
        var b = s; b.id = "builtin"; c.overrides[b.id] = b
        c.settings.hotkeyCode = 2
        let result = try ConfigurationStore.quarantinedImport(JSONEncoder().encode(c), preserving: AppSettings())
        XCTAssertFalse(result.actions[0].approved); XCTAssertFalse(result.custom[0].enabled)
        XCTAssertFalse(result.overrides[b.id]!.enabled); XCTAssertTrue(result.custom[0].confirmation)
        XCTAssertEqual(result.settings.hotkeyCode, AppSettings().hotkeyCode)
    }
    func testUnknownSchemaAndInvalidReferencesRejected() throws {
        var c = Configuration(); c.schemaVersion = 99
        XCTAssertThrowsError(try ConfigurationStore.decode(JSONEncoder().encode(c)))
        c.schemaVersion = 1
        var s = item([.up]); s.steps = [WorkflowStep(actionID: "missing")]; c.custom = [s]
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
    }
    func testInvalidNumbersAndIDsRejected() {
        var c = Configuration(); c.settings.inputTimeout = -1
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
        c = Configuration(); let a = ActionDefinition(); c.actions = [a,a]
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
        c = Configuration(); c.settings.hotkeyModifiers = 0
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
    }
    func testNulArgumentsAndBadEnvironmentRejected() {
        var c = Configuration(); var a = ActionDefinition(); a.arguments = ["a\0b"]; c.actions = [a]
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
        a.arguments = []; a.environment = ["A=B":"x"]; c.actions = [a]
        XCTAssertThrowsError(try ConfigurationStore.validate(c))
    }
    func testSensitiveExportRemovesValues() throws {
        var a = ActionDefinition(); a.sensitive = true; a.target = "SECRET"; a.environment = ["TOKEN":"SECRET"]; a.arguments = ["SECRET"]; a.approved = true
        var c = Configuration(); c.actions = [a]
        let data = try ConfigurationStore.exportData(c)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
        XCTAssertFalse(try ConfigurationStore.decode(data).actions[0].approved)
    }
    func testAtomicPersistenceRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigurationStore(url: dir.appendingPathComponent("config.json"))
        let c = BuiltinCatalog.defaults(builtins: try BuiltinCatalog.load())
        try store.save(c); XCTAssertEqual(try store.load(), c)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testCorruptFileIsNotOverwrittenOnRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("broken".utf8); try data.write(to: file)
        XCTAssertThrowsError(try ConfigurationStore(url: file).load())
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
