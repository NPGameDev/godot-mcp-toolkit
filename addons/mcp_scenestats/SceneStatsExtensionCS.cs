// Example extension: scene statistics (C#).
//
// Registers two commands under a shared group:
// - scenestats_cs.summary      — node count, script count, class breakdown
// - scenestats_cs.find_by_class — list node paths matching a given class
//
// Requires a .NET Godot project with `dotnet build` before discovery.
// C# extensions extend RefCounted directly (cross-language inheritance
// from GDScript is not supported in Godot). The loader discovers them via
// duck typing (has_method("Register")).

using Godot;
using Godot.Collections;

[Tool, GlobalClass]
public partial class MCPToolkitSceneStatsCS : RefCounted
{
    public void Register(GodotObject registry, Node server)
    {
        var group = new Dictionary
        {
            { "name", "scenestats_cs" },
            { "description", "Scene statistics and class search (C#)" },
        };

        registry.Call("add", "scenestats_cs.summary", new Callable(this,
            MethodName.CmdSummary), new Dictionary
        {
            { "description", "Return node count, script count, and class breakdown for the open scene (C#)" },
            { "annotations", new Dictionary { { "readOnlyHint", true }, { "idempotentHint", true } } },
            { "group", group },
        });

        registry.Call("add", "scenestats_cs.find_by_class", new Callable(this,
            MethodName.CmdFindByClass), new Dictionary
        {
            { "description", "Find all nodes matching a given class name in the open scene (C#)" },
            { "input_schema", new Dictionary
            {
                { "type", "object" },
                { "properties", new Dictionary
                {
                    { "class_name", new Dictionary
                    {
                        { "type", "string" },
                        { "description", "Engine class name to search for (e.g., Sprite2D, CharacterBody3D)" },
                    }},
                }},
                { "required", new Array { "class_name" } },
            }},
            { "annotations", new Dictionary { { "readOnlyHint", true }, { "idempotentHint", true } } },
            { "group", group },
        });
    }

    public Dictionary CmdSummary(Dictionary parameters)
    {
        var root = EditorInterface.Singleton.GetEditedSceneRoot();
        if (root == null)
            return new Dictionary { { "success", false }, { "error", "No scene open" }, { "code", "NOT_FOUND" } };

        var stats = new Dictionary
        {
            { "node_count", 0 },
            { "script_count", 0 },
            { "classes", new Dictionary() },
        };
        Walk(root, stats);
        return new Dictionary { { "success", true }, { "data", stats } };
    }

    public Dictionary CmdFindByClass(Dictionary parameters)
    {
        var target = parameters.ContainsKey("class_name") ? (string)parameters["class_name"] : "";
        if (string.IsNullOrEmpty(target))
            return new Dictionary { { "success", false }, { "error", "class_name is required" }, { "code", "INVALID_PARAM" } };

        var root = EditorInterface.Singleton.GetEditedSceneRoot();
        if (root == null)
            return new Dictionary { { "success", false }, { "error", "No scene open" }, { "code", "NOT_FOUND" } };

        var matches = new Array();
        Find(root, target, matches);
        return new Dictionary
        {
            { "success", true },
            { "data", new Dictionary { { "class_name", target }, { "matches", matches }, { "count", matches.Count } } },
        };
    }

    private static void Walk(Node node, Dictionary stats)
    {
        stats["node_count"] = (int)stats["node_count"] + 1;
        var cls = node.GetClass();
        var classes = (Dictionary)stats["classes"];
        if (!classes.ContainsKey(cls))
            classes[cls] = 0;
        classes[cls] = (int)classes[cls] + 1;
        if (node.GetScript().AsGodotObject() != null)
            stats["script_count"] = (int)stats["script_count"] + 1;
        foreach (var child in node.GetChildren())
            Walk(child, stats);
    }

    private static void Find(Node node, string target, Array matches)
    {
        if (node.GetClass() == target || node.IsClass(target))
            matches.Add(node.GetPath().ToString());
        foreach (var child in node.GetChildren())
            Find(child, target, matches);
    }
}
