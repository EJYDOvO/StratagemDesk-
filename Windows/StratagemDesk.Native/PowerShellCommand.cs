using System.Text;
using System.Text.Json;

namespace StratagemDesk.Native;

/// Keeps scripts and arguments off the Windows command line, with user-only access
/// from file creation until disposal after the owned command/process tree has exited.
public sealed class PowerShellCommand : IDisposable
{
    private readonly string directory;
    public string PayloadPath { get; }
    public List<string> Arguments { get; }
    public PowerShellCommand(string script, IReadOnlyList<string> arguments)
    {
        directory = PrivateStorage.CreateTemporaryDirectory();
        PayloadPath = Path.Combine(directory, "payload.json");
        try
        {
            using (var stream = PrivateStorage.CreateFile(PayloadPath))
                JsonSerializer.Serialize(stream, new { script, arguments });
            var path = Convert.ToBase64String(Encoding.UTF8.GetBytes(PayloadPath));
            var wrapper = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " +
                "$f=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + path + "')); " +
                "$p=ConvertFrom-Json ([IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)); " +
                "$argv=@($p.arguments); & ([ScriptBlock]::Create([string]$p.script)) @argv; if($null -ne $LASTEXITCODE){exit $LASTEXITCODE}";
            Arguments = ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(wrapper))];
        }
        catch { Dispose(); throw; }
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
}
