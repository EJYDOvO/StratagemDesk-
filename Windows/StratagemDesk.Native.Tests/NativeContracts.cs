using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using StratagemDesk.Core;

namespace StratagemDesk.Native.Tests;

[TestClass]
public sealed class NativeContracts
{
    [TestMethod] public void ArgumentQuotingHandlesSpacesQuotesAndTrailingSlashes()
    {
        Assert.AreEqual("plain", ProcessRunner.Quote("plain")); Assert.AreEqual("\"\"", ProcessRunner.Quote(""));
        Assert.AreEqual("\"a b\"", ProcessRunner.Quote("a b")); Assert.AreEqual("\"a\\\"b\"", ProcessRunner.Quote("a\"b"));
        Assert.AreEqual("\"a b\\\\\"", ProcessRunner.Quote("a b\\"));
        Assert.ThrowsException<ArgumentException>(() => ProcessRunner.Quote("x\0"));
    }
    private static async Task<CommandResult> Shell(string script, string[]? args = null, CancellationToken token = default)
    {
        using var command = new PowerShellCommand(script, args ?? []);
        var result = await new ProcessRunner().RunAsync(WindowsDefaults.PowerShell, command.Arguments, "", new Dictionary<string, string>(), token);
        return result;
    }
    [TestMethod] public void CustomConfigurationPreservesParentAndSiblingPermissions()
    {
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()));
        try
        {
            var rules = directory.GetAccessControl();
            rules.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            directory.SetAccessControl(rules);
            var sibling = Path.Combine(directory.FullName, "unrelated.txt"); File.WriteAllText(sibling, "keep");
            const AccessControlSections sections = AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group;
            var before = directory.GetAccessControl().GetSecurityDescriptorSddlForm(sections);
            var siblingBefore = new FileInfo(sibling).GetAccessControl().GetSecurityDescriptorSddlForm(sections);
            var path = PrivateStorage.Prepare(Path.Combine(directory.FullName, "configuration.json"));
            var store = new ConfigurationStore(path, [], PrivateStorage.CreateFile); store.Save(new()); store.Backup();
            PrivateStorage.WriteAtomic(Path.Combine(directory.FullName, "last-run.json"), [123, 125]);
            Assert.AreEqual(before, directory.GetAccessControl().GetSecurityDescriptorSddlForm(sections));
            Assert.AreEqual(siblingBefore, new FileInfo(sibling).GetAccessControl().GetSecurityDescriptorSddlForm(sections));
            using var identity = WindowsIdentity.GetCurrent();
            foreach (var file in directory.GetFiles().Where(f => f.Name != "unrelated.txt"))
            {
                var acl = file.GetAccessControl(); Assert.IsTrue(acl.AreAccessRulesProtected);
                Assert.IsTrue(acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().All(r => r.IdentityReference.Equals(identity.User)));
            }
            Assert.IsTrue(Json.Same(new Configuration(), store.Load()));
        }
        finally { directory.Delete(recursive: true); }
    }
    [TestMethod] public async Task LongScriptsAndLargeArgumentsDoNotUseTheCommandLine()
    {
        var value = string.Concat(Enumerable.Repeat("中文 ' \" $() \\ \n", 5000));
        var script = "#" + new string('x', 20000) + "\n[Console]::Write([string]$args[0])";
        string directory;
        using (var command = new PowerShellCommand(script, [value]))
        {
            directory = Path.GetDirectoryName(command.PayloadPath)!;
            Assert.IsTrue(string.Join(" ", command.Arguments).Length < 8000);
            Assert.IsTrue(new FileInfo(command.PayloadPath).GetAccessControl().AreAccessRulesProtected);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var result = await new ProcessRunner().RunAsync(WindowsDefaults.PowerShell, command.Arguments, "", new Dictionary<string, string>(), timeout.Token);
            Assert.AreEqual(0, result.ExitCode); Assert.AreEqual(value, result.Stdout);
        }
        Assert.IsFalse(Directory.Exists(directory));
    }
    [TestMethod] public async Task PayloadIsRemovedAfterCancellationOrLaunchFailure()
    {
        string directory;
        using (var command = new PowerShellCommand("Start-Sleep -Seconds 60", []))
        {
            directory = Path.GetDirectoryName(command.PayloadPath)!;
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var result = await new ProcessRunner().RunAsync(WindowsDefaults.PowerShell, command.Arguments, "", new Dictionary<string, string>(), cancel.Token);
            Assert.IsTrue(result.Cancelled);
        }
        Assert.IsFalse(Directory.Exists(directory));
        using (var command = new PowerShellCommand("Write-Output 'safe'", []))
        {
            directory = Path.GetDirectoryName(command.PayloadPath)!;
            await Assert.ThrowsExceptionAsync<FileNotFoundException>(() => new ProcessRunner().RunAsync("missing.exe", command.Arguments, "", new Dictionary<string, string>(), CancellationToken.None));
        }
        Assert.IsFalse(Directory.Exists(directory));
    }
    [TestMethod] public async Task RealPowerShellPreservesUnicodeAndStructuredArguments()
    {
        var value = "空 格 ' quote \" $(); Write-Output injected\n第二行";
        var r = await Shell("[Console]::Write([string]$args[0])", [value]);
        Assert.AreEqual(0, r.ExitCode); Assert.AreEqual(value, r.Stdout); Assert.IsFalse(r.Cancelled);
    }
    [TestMethod] public async Task OutputFloodIsDrainedAndBounded()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var r = await Shell("[Console]::Out.Write(('x'*1200000)); [Console]::Error.Write(('e'*1200000))", token: timeout.Token);
        Assert.AreEqual(0, r.ExitCode); Assert.IsTrue(r.Truncated); Assert.AreEqual(1_048_576, r.Stdout.Length); Assert.AreEqual(1_048_576, r.Stderr.Length);
    }
    [TestMethod] public async Task CancellationKillsOwnedProcessTree()
    {
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".pid"); using var cancel = new CancellationTokenSource();
        var script = "$s=[Diagnostics.ProcessStartInfo]::new($env:ComSpec); $s.Arguments='/d /c ping -n 60 127.0.0.1'; $s.UseShellExecute=$false; $s.CreateNoWindow=$true; $p=[Diagnostics.Process]::Start($s); [IO.File]::WriteAllText($args[0],[string]$p.Id); Start-Sleep -Seconds 60";
        try
        {
            var task = Shell(script, [file], cancel.Token);
            for (var i = 0; i < 150 && !File.Exists(file); i++) await Task.Delay(100);
            Assert.IsTrue(File.Exists(file), "Child PID was not produced"); var pid = int.Parse(File.ReadAllText(file));
            cancel.Cancel(); var result = await task.WaitAsync(TimeSpan.FromSeconds(10)); Assert.IsTrue(result.Cancelled);
            var alive = false; try { using var p = Process.GetProcessById(pid); alive = !p.HasExited; } catch (ArgumentException) { }
            Assert.IsFalse(alive, "Owned descendant survived cancellation");
        }
        finally { cancel.Cancel(); if (File.Exists(file)) File.Delete(file); }
    }
    [TestMethod] public async Task InvalidExecutableCannotStart()
    {
        await Assert.ThrowsExceptionAsync<FileNotFoundException>(() => new ProcessRunner().RunAsync("relative.exe", [], "", new Dictionary<string, string>(), CancellationToken.None));
    }
    [TestMethod] public void MacSpecificActionsFailExplicitly()
    {
        Assert.IsNotNull(ActionRegistry.UnsupportedReason(new() { Kind = ActionKind.Shortcut }));
        Assert.IsNotNull(ActionRegistry.UnsupportedReason(new() { Kind = ActionKind.Shell, Shell = "/bin/zsh" }));
        Assert.IsNotNull(ActionRegistry.UnsupportedReason(new() { Kind = ActionKind.Application, Target = "com.apple.Terminal" }));
    }
    [TestMethod] public void KeyboardHookCanRegisterDisposeAndReregister()
    {
        var settings = new AppSettings { HotkeyCode = 0x7A, HotkeyModifiers = 3 };
        using (var first = new HotkeyService(0, settings, _ => { })) { }
        using (var second = new HotkeyService(0, settings, _ => { })) { }
    }
    [TestMethod] public void ExactLeftShiftDoesNotReserveGenericShiftTab()
    {
        using var exact = new HotkeyService(0, new() { HotkeyCode = 9, HotkeyModifiers = 4, ExactLeftShift = true }, _ => { });
        using var generic = new HotkeyService(0, new() { HotkeyCode = 9, HotkeyModifiers = 4 }, _ => { });
    }
}
