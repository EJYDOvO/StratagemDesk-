using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using StratagemDesk.Core;

namespace StratagemDesk.Core.Tests;

[TestClass]
public sealed class Contracts
{
    [TestMethod] public void ActivationKeysCannotShadowDirectionOrConfirmationInput()
    {
        foreach (uint key in new uint[] { 0x25, 0x26, 0x27, 0x28, 0x0D, 0x1B })
        {
            var c = new Configuration(); c.Settings.HotkeyCode = key;
            Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Validate(c, []));
        }
        var exact = new Configuration(); exact.Settings = new() { HotkeyCode = 9, HotkeyModifiers = 4, ExactLeftShift = true };
        ConfigurationStore.Validate(exact, []);
    }
    private static Stratagem Entry(params Direction[] sequence) => new() { Enabled = true, Sequence = [.. sequence] };
    private static Configuration Fixture()
    {
        var a = new ActionDefinition { Target = "safe", Approved = true };
        var e = Entry(Direction.Up); e.Steps = [new() { ActionId = a.Id }];
        return new() { Custom = [e], Actions = [a] };
    }
    [TestMethod] public void CatalogAndDefaultsAreSafe()
    {
        var builtins = Catalog.Load(); Assert.AreEqual(8, builtins.Count); Assert.AreEqual(8, builtins.Select(e => e.Id).Distinct().Count());
        Assert.IsTrue(builtins.All(e => !e.Enabled && e.Sequence.Count > 0));
        var c = Catalog.Defaults(builtins); ConfigurationStore.Validate(c, builtins);
        Assert.IsTrue(c.Actions.All(a => !a.Approved)); Assert.IsTrue(c.Resolve(builtins).All(e => !e.Enabled));
    }
    [TestMethod] public void ExactPrefixAndInvalidMatch()
    {
        var e = Entry(Direction.Up, Direction.Down, Direction.Right);
        Assert.AreEqual(MatchKind.Waiting, SequenceMatcher.Match([Direction.Up], [e]).Kind);
        Assert.AreEqual(e.Id, SequenceMatcher.Match(e.Sequence, [e]).Ids.Single());
        Assert.AreEqual(MatchKind.Invalid, SequenceMatcher.Match([Direction.Left], [e]).Kind);
    }
    [TestMethod] public void DisabledAndConflictingEntriesNeverExecute()
    {
        var e = Entry(Direction.Up); e.Enabled = false;
        Assert.AreEqual(MatchKind.Invalid, SequenceMatcher.Match(e.Sequence, [e]).Kind);
        e.Enabled = true; var other = Entry(Direction.Up, Direction.Down);
        Assert.AreEqual(MatchKind.Ambiguous, SequenceMatcher.Match(e.Sequence, [e, other]).Kind);
        Assert.IsTrue(SequenceMatcher.Conflicts([e, other]).Count > 0);
        Assert.IsTrue(SequenceMatcher.Conflicts([Entry()]).Count > 0);
    }
    [TestMethod] public void BulkEnableOnlyChangesSelectedEntries()
    {
        var c = Fixture(); var other = Entry(Direction.Down); c.Custom.Add(other);
        Assert.AreEqual(1, c.SetEnabled([c.Custom[0].Id, "deleted"], false, []));
        Assert.IsFalse(c.Custom[0].Enabled); Assert.IsTrue(c.Custom[1].Enabled); Assert.IsTrue(c.Actions[0].Approved);
        Assert.AreEqual(0, c.SetEnabled([], false, []));
    }
    [TestMethod] public void ProfilesCompareContentInsteadOfGeneratedIds()
    {
        var c = Fixture(); var p = c.Profile(c.Custom[0].Id, [])!; var q = Json.Clone(c).Profile(c.Custom[0].Id, [])!;
        q.Actions[0].Id = "replacement"; q.Entry.Steps[0].Id = "other"; q.Entry.Steps[0].ActionId = "replacement";
        Assert.IsTrue(p.Equivalent(q)); q.Actions[0].Target = "changed"; Assert.IsFalse(p.Equivalent(q));
    }
    [TestMethod] public void SharedActionEditsAreIsolatedAndUndoRemovesOrphans()
    {
        var c = Fixture(); var first = c.Custom[0]; var other = Entry(Direction.Down); other.Steps = Json.Clone(first.Steps); c.Custom.Add(other);
        var before = c.Profile(other.Id, [])!; var p = c.Profile(first.Id, [])!;
        var original = Json.Clone(c); p.Actions[0].Target = "changed"; p.Actions[0].Approved = false; c.Apply(p, []);
        Assert.IsTrue(before.Equivalent(c.Profile(other.Id, [])!)); Assert.AreEqual(2, c.Actions.Count);
        c.Apply(original.Profile(first.Id, [])!, []); Assert.AreEqual(1, c.Actions.Count);
    }
    [TestMethod] public void SingleSaveLeavesOtherDraftsAndSettingsOut()
    {
        var saved = Fixture(); saved.Custom.Add(Entry(Direction.Down)); var draft = Json.Clone(saved);
        draft.Custom[0].Name = "save me"; draft.Custom[1].Name = "draft"; draft.Settings.InputTimeout = 17;
        saved.Apply(draft.Profile(draft.Custom[0].Id, [])!, []);
        Assert.AreEqual("save me", saved.Custom[0].Name); Assert.AreNotEqual("draft", saved.Custom[1].Name);
        Assert.AreEqual(5d, saved.Settings.InputTimeout); Assert.AreEqual("draft", draft.Custom[1].Name);
    }
    [TestMethod] public void DefaultRestoreIncludesWorkflowAndRevokesApproval()
    {
        var builtins = Catalog.Load(); var c = Catalog.Defaults(builtins);
        const string id = "desk.workflow";
        var original = c.Profile(id, builtins)!; var p = c.Profile(id, builtins)!;
        p.Actions[0].Target = "edited"; p.Actions[0].Approved = true; c.Apply(p, builtins); c.Apply(original, builtins);
        Assert.IsTrue(original.Equivalent(c.Profile(id, builtins)!)); Assert.IsFalse(c.Profile(id, builtins)!.Actions[0].Approved);
    }
    [TestMethod] public void ImportRevokesApprovalAndPreservesWindowsSettings()
    {
        var c = Fixture(); c.Custom[0].Confirmation = false; c.Settings.HotkeyCode = 1; c.Settings.HotkeyModifiers = 2304;
        var result = ConfigurationStore.QuarantinedImport(Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(c, Json.Options)), new(), []);
        Assert.IsFalse(result.Custom[0].Enabled); Assert.IsTrue(result.Custom[0].Confirmation); Assert.IsFalse(result.Actions[0].Approved);
        Assert.AreEqual(0x53u, result.Settings.HotkeyCode); Assert.AreEqual(3u, result.Settings.HotkeyModifiers);
    }
    [TestMethod] public void SensitiveExportContainsNoValues()
    {
        var c = Fixture(); c.Actions[0].Sensitive = true; c.Actions[0].Target = "SECRET";
        c.Actions[0].Environment["TOKEN"] = "SECRET"; c.Actions[0].Arguments.Add("SECRET");
        var data = ConfigurationStore.Export(c); Assert.IsFalse(Encoding.UTF8.GetString(data).Contains("SECRET", StringComparison.Ordinal));
        Assert.IsFalse(ConfigurationStore.Decode(data, []).Actions[0].Approved);
    }
    [TestMethod] public void InvalidReferencesAndNumbersAreRejected()
    {
        var c = Fixture(); c.Custom[0].Steps[0].ActionId = "missing"; Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Validate(c, []));
        c = Fixture(); c.Settings.InputTimeout = double.NaN; Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Validate(c, []));
        c = Fixture(); c.Actions[0].Environment = new() { ["A"] = "x", ["a"] = "y" }; Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Validate(c, []));
        c = Fixture(); c.Actions[0].Target = "bad\0value"; Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Validate(c, []));
    }
    [TestMethod] public void StoreRoundTripAndConflictFailurePreserveDisk()
    {
        var dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var store = new ConfigurationStore(Path.Combine(dir, "config.json"), []); var c = Fixture(); store.Save(c);
            Assert.IsTrue(Json.Same(c, store.Load())); var before = File.ReadAllBytes(store.FilePath);
            c.Custom.Add(Entry(Direction.Up, Direction.Down)); Assert.ThrowsException<InvalidDataException>(() => store.Save(c));
            CollectionAssert.AreEqual(before, File.ReadAllBytes(store.FilePath));
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }
    [TestMethod] public void CorruptConfigurationIsNotOverwritten()
    {
        var path = Path.GetTempFileName(); try { File.WriteAllText(path, "broken"); var s = new ConfigurationStore(path, []);
            Assert.ThrowsException<System.Text.Json.JsonException>(() => s.Load()); Assert.AreEqual("broken", File.ReadAllText(path)); }
        finally { File.Delete(path); }
    }
    [TestMethod] public void HoldIgnoresReleasedInputAndRepeats()
    {
        var h = new HoldState(new()); Assert.IsFalse(h.Handle(0x26, true).Consume); h.Handle(0x26, false);
        h.Handle(0xA2, true); h.Handle(0xA4, true);
        CollectionAssert.AreEqual(new[] { HoldEffect.Began }, h.Handle(0x53, true).Effects);
        Assert.AreEqual(0, h.Handle(0x53, true).Effects.Count);
        CollectionAssert.AreEqual(new[] { HoldEffect.Up }, h.Handle(0x26, true).Effects);
        Assert.AreEqual(0, h.Handle(0x26, true).Effects.Count);
        Assert.IsTrue(h.Handle(0x26, false).Consume);
        CollectionAssert.AreEqual(new[] { HoldEffect.Ended }, h.Handle(0x53, false).Effects); Assert.IsFalse(h.Active);
    }
    [TestMethod] public void ModifierReleaseAndEscCannotReopenHeldChord()
    {
        var h = new HoldState(new()); h.Handle(0xA2, true); h.Handle(0xA4, true); h.Handle(0x53, true);
        Assert.IsTrue(h.Handle(0xA4, false).Effects.Contains(HoldEffect.Ended)); h.Handle(0xA4, true);
        Assert.AreEqual(0, h.Handle(0x53, true).Effects.Count); h.Handle(0x53, false); h.Handle(0x53, true);
        Assert.IsTrue(h.Active); Assert.IsTrue(h.Handle(0x1B, true).Effects.Contains(HoldEffect.Cancel));
        Assert.IsFalse(h.Active); Assert.AreEqual(0, h.Handle(0x53, true).Effects.Count); Assert.IsTrue(h.Handle(0x1B, false).Consume);
    }
    [TestMethod] public void ExactLeftShiftDoesNotAcceptRightShift()
    {
        var h = new HoldState(new() { HotkeyCode = 9, HotkeyModifiers = 4, ExactLeftShift = true });
        h.Handle(0xA1, true); Assert.IsFalse(h.Handle(9, true).Consume); h.Handle(9, false); h.Handle(0xA1, false);
        h.Handle(0xA0, true); Assert.IsTrue(h.Handle(9, true).Effects.Contains(HoldEffect.Began));
    }
    [TestMethod] public void AdditionalModifierDoesNotEndOrdinaryHold()
    {
        var h = new HoldState(new()); h.Handle(0xA2, true); h.Handle(0xA4, true); h.Handle(0x53, true);
        Assert.AreEqual(0, h.Handle(0xA0, true).Effects.Count); Assert.IsTrue(h.Active);
        Assert.IsTrue(h.Handle(0xA2, false).Effects.Contains(HoldEffect.Ended));
    }
    [TestMethod] public async Task WorkflowSnapshotsAndSingleFlight()
    {
        var c = Fixture(); var runner = new WorkflowRunner(); var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        var task = runner.RunAsync(c.Custom[0], c, async (a, token) => { entered.SetResult(); await release.Task.WaitAsync(token); return new(true, a.Target); });
        await entered.Task; c.Actions[0].Target = "draft";
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() => runner.RunAsync(c.Custom[0], c, (_, _) => Task.FromResult(new ActionOutcome(true, ""))));
        release.SetResult(); var result = await task; Assert.AreEqual(RunStatus.Succeeded, result.Status); Assert.AreEqual("safe", result.Logs[0].Detail);
    }
    [TestMethod] public async Task WorkflowApprovalAndTimeoutAreEnforced()
    {
        var c = Fixture(); c.Actions[0].Approved = false; var runner = new WorkflowRunner(); var calls = 0;
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() => runner.RunAsync(c.Custom[0], c, (_, _) => { calls++; return Task.FromResult(new ActionOutcome(true, "")); }));
        Assert.AreEqual(0, calls); c.Actions[0].Approved = true; c.Actions[0].Timeout = .1;
        var r = await runner.RunAsync(c.Custom[0], c, async (_, token) => { await Task.Delay(5000, token); return new(true, ""); });
        Assert.AreEqual(RunStatus.Failed, r.Status); Assert.IsNull(runner.RunningId);
    }
    [TestMethod] public async Task WorkflowCancelStopsFollowingSteps()
    {
        var c = Fixture(); c.Custom[0].Steps.Add(new() { ActionId = c.Actions[0].Id }); var runner = new WorkflowRunner(); var entered = new TaskCompletionSource(); var calls = 0;
        var task = runner.RunAsync(c.Custom[0], c, async (_, token) => { calls++; entered.TrySetResult(); await Task.Delay(5000, token); return new(true, ""); });
        await entered.Task; runner.Cancel(); Assert.AreEqual(RunStatus.Cancelled, (await task).Status); Assert.AreEqual(1, calls);
    }
    [TestMethod] public async Task SensitiveWorkflowRedactsFollowingOutputs()
    {
        var c = Fixture(); c.Actions[0].Sensitive = true;
        var second = new ActionDefinition { Approved = true }; c.Actions.Add(second); c.Custom[0].Steps.Add(new() { ActionId = second.Id });
        var runner = new WorkflowRunner(); var r = await runner.RunAsync(c.Custom[0], c, (_, _) => Task.FromResult(new ActionOutcome(true, "SECRET")));
        Assert.AreEqual(2, r.Logs.Count); Assert.IsTrue(r.Logs.All(l => !l.Detail.Contains("SECRET", StringComparison.Ordinal)));
    }
    [TestMethod] public async Task FailureContinueRecordsFinalFailure()
    {
        var c = Fixture(); c.Custom[0].Steps[0].ContinueOnFailure = true; c.Custom[0].Steps.Add(new() { ActionId = c.Actions[0].Id });
        var calls = 0; var runner = new WorkflowRunner(); var r = await runner.RunAsync(c.Custom[0], c, (_, _) => Task.FromResult(new ActionOutcome(++calls > 1, "result")));
        Assert.AreEqual(2, calls); Assert.AreEqual(RunStatus.Failed, r.Status);
    }
}
