import Foundation
import Testing
@testable import TetherCore

@Test func fileSearchFindsNestedNamesBySubstring() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    files.addShare(name: "Photos", writable: false)
    try files.writeFile(path: "/Docs/Notes.txt", data: Data("a".utf8))
    try files.writeFile(path: "/Docs/Project/readme.md", data: Data("b".utf8))
    try files.writeFile(path: "/Photos/readme.jpg", data: Data("c".utf8))

    let hits = try await FileSearch.find(
        pattern: "read",
        root: .root,
        match: .substring,
        includeDirectories: true,
        list: { path in
            try await files.list(path: path, offset: 0, limit: 1000, includeHidden: false)
        }
    )
    let paths = Set(hits.map(\.path))
    #expect(paths.contains("/Docs/Project/readme.md"))
    #expect(paths.contains("/Photos/readme.jpg"))
    #expect(!paths.contains("/Docs/Notes.txt"))
}

@Test func fileSearchWildcardMatchesTerminalFindStyle() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    try files.writeFile(path: "/Docs/alpha.txt", data: Data())
    try files.writeFile(path: "/Docs/beta.txt", data: Data())
    try files.writeFile(path: "/Docs/gamma.md", data: Data())

    let hits = try await FileSearch.find(
        pattern: "*.txt",
        root: try VirtualPath.parse("/Docs"),
        match: .wildcard,
        includeDirectories: false,
        list: { path in
            try await files.list(path: path, offset: 0, limit: 1000, includeHidden: false)
        }
    )
    #expect(Set(hits.map(\.path)) == Set(["/Docs/alpha.txt", "/Docs/beta.txt"]))
}

@Test func terminalFindUsesSharedFileSearch() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    try files.writeFile(path: "/Docs/deep/file.txt", data: Data("x".utf8))
    let result = await TerminalEngine().execute(line: "find file.txt /", cwd: "/", files: files)
    #expect(result.stdout.contains("/Docs/deep/file.txt"))
}
