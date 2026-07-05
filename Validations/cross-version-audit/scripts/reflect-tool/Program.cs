// reflect-tool --- reflection-only surface dump of GodotSharp[Editor].dll.
// See reflect-tool.csproj for rationale. Usage: <ApiDir> <OutJson>.
using System.Reflection;
using System.Text.Json;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: reflect-tool <Api/Debug dir> <out.json>");
    return 2;
}
string apiDir = args[0];
string outPath = args[1];

var targets = new[] { "GodotSharp.dll", "GodotSharpEditor.dll" }
    .Select(n => Path.Combine(apiDir, n))
    .Where(File.Exists)
    .ToArray();
if (targets.Length == 0)
{
    Console.Error.WriteLine($"no GodotSharp*.dll under: {apiDir}");
    return 1;
}

// Resolver: the Api dir's DLLs + the current runtime's core assemblies. Dedup by
// simple name (PathAssemblyResolver rejects duplicate identities); the Api dir wins.
// PathAssemblyResolver matches by simple name ignoring version, so an 8.0 core lib
// resolves 4.2's net6.0 references at the metadata level.
var runtimeDir = Path.GetDirectoryName(typeof(object).Assembly.Location)!;
var bySimpleName = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
foreach (var p in Directory.GetFiles(apiDir, "*.dll"))
    bySimpleName[Path.GetFileNameWithoutExtension(p)] = p;
foreach (var p in Directory.GetFiles(runtimeDir, "*.dll"))
    bySimpleName.TryAdd(Path.GetFileNameWithoutExtension(p), p);

var resolver = new PathAssemblyResolver(bySimpleName.Values);
using var mlc = new MetadataLoadContext(resolver);

const BindingFlags Bf = BindingFlags.Public | BindingFlags.Instance
    | BindingFlags.Static | BindingFlags.DeclaredOnly;

var types = new SortedDictionary<string, object>(StringComparer.Ordinal);
foreach (var dll in targets)
{
    var asm = mlc.LoadFromAssemblyPath(dll);
    Type?[] loaded;
    try { loaded = asm.GetTypes(); }
    catch (ReflectionTypeLoadException ex) { loaded = ex.Types; }

    foreach (var t in loaded)
    {
        if (t is null || !t.IsPublic) continue;
        var ns = t.Namespace ?? "";
        if (ns != "Godot" && !ns.StartsWith("Godot.")) continue;

        var methods = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var m in t.GetMethods(Bf))
            if (!m.IsSpecialName) methods.Add(m.Name);   // skip get_/set_/op_ accessors
        var props = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var p in t.GetProperties(Bf))
            props.Add(p.Name);

        types[t.Name] = new
        {
            full = t.FullName,
            assembly = Path.GetFileName(dll),
            is_enum = t.IsEnum,
            methods = methods.ToArray(),
            properties = props.ToArray(),
        };
    }
}

var result = new
{
    assemblies = targets.Select(Path.GetFileName).ToArray(),
    source = apiDir,
    type_count = types.Count,
    types,
};
File.WriteAllText(outPath, JsonSerializer.Serialize(result));
Console.WriteLine($"reflected {types.Count} Godot types -> {outPath}");
return 0;
