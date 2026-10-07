import Foundation
import Testing
@testable import TetherCore

@Test func tabCompletesAFolderAndKeepsItOpen() {
    let names = [
        CompletionName(name: "Documents", isDirectory: true),
        CompletionName(name: "Photos", isDirectory: true),
    ]
    let outcome = complete("cd doc", names: names)
    #expect(outcome.line == "cd Documents/")
    #expect(outcome.hint.isEmpty)
    #expect(outcome.suggestions.isEmpty)
}

@Test func tabCompletesAFileUsingTheRealSpelling() {
    let names = [CompletionName(name: "README.md", isDirectory: false)]
    let outcome = complete("cat readme", names: names)
    #expect(outcome.line == "cat README.md ")
    #expect(outcome.hint.isEmpty)
}

@Test func tabLooksInsideTheTypedFolder() {
    let request = LineCompletion.request(line: "ls src/ma", cwd: "/Docs/Project")
    #expect(request.directory == "/Docs/Project/src")
    #expect(request.prefix == "ma")
    let outcome = LineCompletion.complete(
        line: "ls src/ma",
        request: request,
        names: [CompletionName(name: "Main.swift", isDirectory: false)],
        commands: []
    )
    #expect(outcome.line == "ls src/Main.swift ")
}

@Test func tabDoesNotPickTheFirstFolderWhenSeveralMatch() {
    let names = [
        CompletionName(name: "Documents", isDirectory: true),
        CompletionName(name: "Downloads", isDirectory: true),
    ]
    let grown = complete("ls D", names: names)
    #expect(grown.line == "ls Do")
    #expect(grown.suggestions.map(\.display) == ["Documents", "Downloads"])
    #expect(grown.suggestions.allSatisfy { $0.isDirectory })

    let stuck = complete("ls Do", names: names)
    #expect(stuck.line == "ls Do")
    #expect(stuck.suggestions.map(\.display) == ["Documents", "Downloads"])
}

@Test func tabQuotesANameThatContainsASpace() {
    let names = [CompletionName(name: "My File.txt", isDirectory: false)]
    let outcome = complete("cat \"my fi", names: names)
    #expect(outcome.line == "cat \"My File.txt\" ")
}

@Test func tabCompletesCommandsSeparatelyFromFileNames() {
    let commands = ["cat", "cd", "clear", "ls"]
    let partial = LineCompletion.complete(
        line: "c",
        request: LineCompletion.request(line: "c", cwd: "/Docs"),
        names: [CompletionName(name: "camera.txt", isDirectory: false)],
        commands: commands
    )
    #expect(partial.line == "c")
    #expect(Set(partial.suggestions.map(\.display)) == Set(["cat", "cd", "clear"]))
    #expect(!partial.suggestions.map(\.display).contains("camera"))

    let unique = LineCompletion.complete(
        line: "cle",
        request: LineCompletion.request(line: "cle", cwd: "/Docs"),
        names: [],
        commands: commands
    )
    #expect(unique.line == "clear ")
}

@Test func tabOnAnEmptyArgumentListsTheWorkingFolder() {
    let request = LineCompletion.request(line: "ls ", cwd: "/Docs")
    #expect(request.listsFiles)
    #expect(request.directory == "/Docs")
    #expect(request.prefix.isEmpty)
    let outcome = LineCompletion.complete(
        line: "ls ",
        request: request,
        names: [CompletionName(name: "notes.txt", isDirectory: false)],
        commands: []
    )
    #expect(outcome.line == "ls notes.txt ")
}

@Test func tildeCompletesFromTheTopOfTheShares() {
    let request = LineCompletion.request(line: "cd ~/Do", cwd: "/Docs")
    #expect(request.directory == "/")
    #expect(request.prefix == "Do")
    let parent = LineCompletion.request(line: "cd ../a", cwd: "/Docs/Sub")
    #expect(parent.directory == "/Docs")
    #expect(parent.prefix == "a")
}

@Test func suggestionsListAmbiguousFoldersWithoutRewriting() {
    let request = LineCompletion.request(line: "cd co", cwd: "/")
    let names = [
        CompletionName(name: "Codes", isDirectory: true),
        CompletionName(name: "configs", isDirectory: true),
    ]
    let listed = LineCompletion.suggestions(request: request, names: names, commands: [])
    #expect(listed.map(\.display) == ["Codes", "configs"])
    #expect(listed.allSatisfy { $0.kind == .folder })
}

@Test func tabKeepsEveryMatchForALargeFolder() {
    let names = (1...60).map { CompletionName(name: String(format: "file-%02d.txt", $0), isDirectory: false) }
    let outcome = complete("get ", names: names)
    #expect(outcome.suggestions.count == 60)
    #expect(outcome.suggestions.first?.display == "file-01.txt")
    #expect(outcome.suggestions.last?.display == "file-60.txt")
    #expect(outcome.hint.contains("60 matches"))
}

@Test func applyInsertsAPickedFolderAndKeepsItOpen() {
    let line = "cd co"
    let request = LineCompletion.request(line: line, cwd: "/")
    let pick = CompletionSuggestion(display: "Codes", insert: "Codes/", isDirectory: true, kind: .folder)
    let next = LineCompletion.apply(line: line, request: request, suggestion: pick)
    #expect(next == "cd Codes/")
}

@Test func applyInsertsACommandPrefixFromTheCatalog() {
    let line = "ge"
    let request = LineCompletion.request(line: line, cwd: "/")
    let pick = CompletionSuggestion(display: "get", insert: "get ", isDirectory: false, kind: .command)
    let next = LineCompletion.apply(line: line, request: request, suggestion: pick)
    #expect(next == "get ")
}

@Test func commandCatalogCoversEveryVirtualCommandName() {
    let catalog = Set(CommandCatalog.entries.map(\.name))
    let agents = AgentPrograms.names
    let virtual = TerminalEngine.commandNames.filter { !agents.contains($0.lowercased()) }
    for name in virtual {
        #expect(catalog.contains(name), "CommandHelp missing \(name)")
    }
    for entry in CommandCatalog.entries {
        #expect(virtual.contains(entry.name), "Orphan CommandHelp \(entry.name)")
    }
}

@Test func commandCatalogExposesTypedSyntaxForCommonCommands() throws {
    let get = try #require(CommandCatalog.entry(named: "get"))
    #expect(get.syntax == "get <file>")
    let ls = try #require(CommandCatalog.entry(named: "ls"))
    #expect(ls.syntax.contains("[-l]"))
    let head = try #require(CommandCatalog.entry(named: "head"))
    #expect(head.syntax.contains("-n"))
    let printed = CommandCatalog.printedHelp()
    #expect(printed.contains("get <file>"))
    #expect(printed.contains("ls [-l] [-a] [path]"))
}

private func complete(_ line: String, names: [CompletionName]) -> CompletionOutcome {
    let request = LineCompletion.request(line: line, cwd: "/Docs")
    return LineCompletion.complete(line: line, request: request, names: names, commands: TerminalEngine.commandNames)
}
