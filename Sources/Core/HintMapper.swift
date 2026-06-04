import Foundation

public enum HintMapper {
    public static func hint(forTool tool: String) -> String {
        let t = tool.lowercased()
        if t.contains("search") || t.contains("grep") || t.contains("find") || t.contains("glob") {
            return "SEARCHING…"
        }
        if t.contains("read") || t.contains("fetch") || t.contains("cat") || t.contains("get") {
            return "READING…"
        }
        if t.contains("write") || t.contains("edit") || t.contains("apply") || t.contains("patch") {
            return "WRITING…"
        }
        if t.contains("exec") || t.contains("bash") || t.contains("shell") || t.contains("run") {
            return "RUNNING…"
        }
        let name = tool.uppercased()
        return name.count > 12 ? name.prefix(12) + "…" : name + "…"
    }
}
