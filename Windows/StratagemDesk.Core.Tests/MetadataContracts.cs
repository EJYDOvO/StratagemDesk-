using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using StratagemDesk.Core;

namespace StratagemDesk.Core.Tests;

[TestClass]
public sealed class MetadataContracts
{
    [DataTestMethod]
    [DataRow("name")]
    [DataRow("icon")]
    [DataRow("category")]
    [DataRow("description")]
    public void NullPresentationFieldsCannotReplaceSavedConfiguration(string field)
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var store = new ConfigurationStore(Path.Combine(directory, "configuration.json"), []);
        var original = new Configuration { Custom = [new() { Name = "Retain this profile" }] };
        try
        {
            store.Save(original); var before = File.ReadAllBytes(store.FilePath);
            var document = JsonNode.Parse(JsonSerializer.Serialize(original, Json.Options))!;
            document["custom"]![0]![field] = null;
            var bytes = Encoding.UTF8.GetBytes(document.ToJsonString());
            Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Decode(bytes, []));
            Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.QuarantinedImport(bytes, new(), []));
            var invalid = JsonSerializer.Deserialize<Configuration>(bytes, Json.Options)!;
            Assert.ThrowsException<InvalidDataException>(() => store.Save(invalid));
            CollectionAssert.AreEqual(before, File.ReadAllBytes(store.FilePath));
            Assert.AreEqual("Retain this profile", store.Load().Custom.Single().Name);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }
    [TestMethod]
    public void PresentationFieldsRejectNulButAllowEmptyFallbackMetadata()
    {
        var config = new Configuration { Custom = [new() { Name = "Valid", Icon = "", Category = "", Description = "" }] };
        ConfigurationStore.Validate(config, []);
        foreach (var field in new[] { "name", "icon", "category", "description" })
        {
            var document = JsonNode.Parse(JsonSerializer.Serialize(config, Json.Options))!;
            document["custom"]![0]![field] = "invalid\0metadata";
            Assert.ThrowsException<InvalidDataException>(() => ConfigurationStore.Decode(Encoding.UTF8.GetBytes(document.ToJsonString()), []));
        }
    }
    [TestMethod]
    public void ImportResetsFileArtworkWithoutChangingWorkflowReferences()
    {
        var builtins = Catalog.Load();
        foreach (var path in new[] { @"\\127.0.0.1\no-share\icon.png", @"C:\Pictures\icon.svg", @"\\?\UNC\127.0.0.1\no-share\icon.svg", "/tmp/foreign-icon.svg", "relative/icon.png" })
        {
            var action = new ActionDefinition { Approved = true, Target = "Write-Output safe" };
            var custom = new Stratagem { Icon = path, Enabled = true, Sequence = [Direction.Up], Steps = [new() { ActionId = action.Id }] };
            var builtin = Json.Clone(builtins[0]); builtin.Icon = path; builtin.Enabled = true;
            var config = new Configuration { Custom = [custom], Actions = [action], Overrides = { [builtin.Id] = builtin } };
            var imported = ConfigurationStore.QuarantinedImport(JsonSerializer.SerializeToUtf8Bytes(config, Json.Options), new(), builtins);
            Assert.AreEqual("command.square", imported.Custom.Single().Icon);
            Assert.AreEqual(builtins[0].Icon, imported.Overrides[builtin.Id].Icon);
            Assert.IsFalse(imported.Custom[0].Enabled); Assert.IsFalse(imported.Actions[0].Approved);
            Assert.AreEqual(action.Id, imported.Custom[0].Steps[0].ActionId);
            CollectionAssert.AreEqual(custom.Sequence, imported.Custom[0].Sequence);
        }
        var unchanged = new Configuration { Custom = [new() { Icon = "command.square" }] };
        var result = ConfigurationStore.QuarantinedImport(JsonSerializer.SerializeToUtf8Bytes(unchanged, Json.Options), new(), builtins);
        Assert.AreEqual("command.square", result.Custom.Single().Icon);
    }
}
