using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;

namespace StratagemDesk.Native;

public static class PrivateStorage
{
    public static string Prepare(string? isolatedPath = null)
    {
        var path = Path.GetFullPath(isolatedPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StratagemDesk-Public", "configuration.json"));
        var directory = new DirectoryInfo(Path.GetDirectoryName(path)!);
        // Only the application's default directory belongs to us. A custom file may
        // live in Documents or a shared directory: never rewrite its parent's ACL.
        if (isolatedPath == null) { directory.Create(DirectoryRules()); directory.SetAccessControl(DirectoryRules()); }
        else directory.Create();
        return path;
    }
    private static SecurityIdentifier CurrentUser
    {
        get { using var identity = WindowsIdentity.GetCurrent(); return identity.User ?? throw new UnauthorizedAccessException("无法确认当前 Windows 用户"); }
    }
    private static DirectorySecurity DirectoryRules()
    {
        var sid = CurrentUser; var security = new DirectorySecurity(); security.SetOwner(sid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }
    public static string CreateTemporaryDirectory()
    {
        var directory = new DirectoryInfo(Path.Combine(Path.GetTempPath(), "StratagemDesk-" + Guid.NewGuid()));
        directory.Create(DirectoryRules()); return directory.FullName;
    }
    public static FileStream CreateFile(string path)
    {
        var sid = CurrentUser; var security = new FileSecurity(); security.SetOwner(sid);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        return new FileInfo(path).Create(FileMode.CreateNew, FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, security);
    }
    public static void WriteAtomic(string path, byte[] data)
    {
        var temp = path + "." + Guid.NewGuid() + ".tmp";
        try
        {
            using (var stream = CreateFile(temp)) { stream.Write(data); stream.Flush(flushToDisk: true); }
            File.Move(temp, path, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static void SetLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("StratagemDeskPublic", ProcessRunner.Quote(Environment.ProcessPath ?? throw new InvalidOperationException("应用路径不可用")));
        else key.DeleteValue("StratagemDeskPublic", throwOnMissingValue: false);
    }
}
