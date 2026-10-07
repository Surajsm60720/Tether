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
    #expect(grown.hint.contains("Documents"))
    #expect(grown.hint.contains("Downloads"))

    let stuck = complete("ls Do", names: names)
    #expect(stuck.line == "ls Do")
    #expect(stuck.hint.contains("Documents"))
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
    #expect(partial.hint.contains("cat"))
    #expect(partial.hint.contains("clear"))
    #expect(!partial.hint.contains("camera"))

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

private func complete(_ line: String, names: [CompletionName]) -> CompletionOutcome {
    let request = LineCompletion.request(line: line, cwd: "/Docs")
    return LineCompletion.complete(line: line, request: request, names: names, commands: TerminalEngine.commandNames)
}
