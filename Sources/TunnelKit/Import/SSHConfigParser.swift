public enum SSHConfigParser {
    /// Concrete `Host` aliases, in file order; patterns (`*`, `?`, `!`) are skipped. `Include` is not followed.
    public static func hosts(in text: String) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = words.first, keyword.lowercased() == "host" else { continue }
            for name in words.dropFirst() where !name.contains(where: { "*?!".contains($0) }) {
                let alias = String(name)
                if !result.contains(alias) { result.append(alias) }
            }
        }
        return result
    }
}
