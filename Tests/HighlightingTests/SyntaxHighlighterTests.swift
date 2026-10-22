import Foundation
import SeamCore
import Testing

@testable import Highlighting

@Suite struct SyntaxHighlighterTests {
    /// One snippet per grammar, with a word on its first line and the token it must get.
    static let samples: [(SyntaxLanguage, String, String, SyntaxToken)] = [
        (.csharp, "public class Order { }\n", "public", .keyword),
        (.typescript, "const total: number = 1;\n", "number", .type),
        (.tsx, "const view = <div>hi</div>;\n", "const", .keyword),
        (.javascript, "function add(a) { return a; }\n", "function", .keyword),
        (.json, "{\"key\": 1}\n", "1", .number),
        (.yaml, "name: \"seam\"\n", "\"seam\"", .string),
        (.markdown, "# Title\n", "Title", .heading),
        (.xml, "<Project Sdk=\"x\"></Project>\n", "Project", .tag),
        (.rust, "fn main() {}\n", "fn", .keyword),
        (.toml, "name = \"seam\"\n", "\"seam\"", .string),
        (.dockerfile, "FROM swift:6\n", "FROM", .keyword),
        (.php, "<?php $name = \"seam\";\n", "\"seam\"", .string),
    ]

    @Test(arguments: SyntaxLanguage.allCases)
    func everyGrammarAndQueryHighlightsItsSample(language: SyntaxLanguage) async throws {
        let (_, text, word, token) = try #require(Self.samples.first { $0.0 == language })
        let lines = try #require(await SyntaxHighlighter().highlight(text, as: language)?.lines)
        let line = try #require(lines.first)
        let start = try #require(text.range(of: word)).lowerBound
        let offset = text.distance(from: text.startIndex, to: start)
        let span = line.first { $0.range.contains(offset) }
        #expect(span?.token == token, "\(language): \(line)")
    }

    @Test(arguments: [
        (
            SyntaxLanguage.csharp,
            "namespace A;\npublic sealed class Handler(int x)\n{\n    public int Handle()\n    {\n        return x;\n    }\n}\n",
            ["Handler", "Handle"]
        ),
        (
            .typescript,
            "export class Cart {\n  total(): number {\n    return 1;\n  }\n}\nconst f = () => {\n  return 2;\n};\n",
            ["Cart", "total"]
        ),
        (
            .rust, "impl Cart {\n    fn total(&self) -> i32 {\n        1\n    }\n}\n",
            ["Cart", "total"]
        ),
        (
            .php,
            "<?php\nclass Cart\n{\n    public function total(): int\n    {\n        return 1;\n    }\n}\n",
            ["Cart", "total"]
        ),
    ])
    func definitionsAroundALineAreNamedOutermostFirst(
        language: SyntaxLanguage, text: String, expected: [String]
    ) async throws {
        let scopes = try #require(await SyntaxHighlighter().highlight(text, as: language)?.scopes)
        let line = try #require(
            text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
                $0.contains("return") || $0.trimmingCharacters(in: .whitespaces) == "1"
            })
        #expect(SyntaxScope.names(around: line, in: scopes) == expected)
    }

    @Test func aFunctionHeldInAVariableIsNamed() async throws {
        let text = "const handle = async () => {\n  return 1;\n};\n"
        let scopes = try #require(
            await SyntaxHighlighter().highlight(text, as: .typescript)?.scopes)
        #expect(SyntaxScope.names(around: 1, in: scopes) == ["handle"])
    }

    @Test func cSharpCallsReturnTypesAndNamespacesAreHighlighted() async throws {
        let text = """
            namespace Shop.Orders;

            class T
            {
                public async Task Run()
                {
                    await TakeAwayAsync(data);
                    Map<int>(x);
                }
            }

            """
        let lines = try #require(await SyntaxHighlighter().highlight(text, as: .csharp)?.lines)
        let source = text.components(separatedBy: "\n").map(Array.init)
        func token(_ word: String, line: Int) -> SyntaxToken? {
            let characters = source[line]
            let start = (0...(characters.count - word.count)).first {
                String(characters[$0..<($0 + word.count)]) == word
            }
            return start.flatMap { start in lines[line].first { $0.range.contains(start) }?.token }
        }
        #expect(token("Orders", line: 0) == .type)
        #expect(token("Task", line: 4) == .type)
        #expect(token("TakeAwayAsync", line: 6) == .function)
        #expect(token("Map", line: 7) == .function)
    }

    @Test func phpClassNamesBeforeDoubleColonsAreTypes() async throws {
        let text = "<?php $a = [Client::class, Client::NAME, Client::$cache, Client::make()];\n"
        let line = try #require(await SyntaxHighlighter().highlight(text, as: .php)?.lines.first)
        let characters = Array(text)
        let starts = (0..<characters.count).filter {
            $0 + 6 <= characters.count && String(characters[$0..<($0 + 6)]) == "Client"
        }
        #expect(starts.count == 4)
        for start in starts {
            #expect(line.first { $0.range.contains(start) }?.token == .type, "at \(start)")
        }
    }

    @Test func aBlockCommentIsHighlightedOnEveryLineItSpans() async throws {
        let text = "/* first\n   second */\nint x = 1;\n"
        let lines = try #require(await SyntaxHighlighter().highlight(text, as: .csharp)?.lines)
        #expect(lines.count == 3)
        #expect(lines[1].first == SyntaxSpan(range: 0..<12, token: .comment))
        #expect(lines[2].contains { $0.token == .keyword || $0.token == .type })
    }

    @Test func offsetsAreCharactersEvenAfterWideOnes() async throws {
        let text = "const a = \"🎉\" + \"å\";\n"
        let lines = try #require(await SyntaxHighlighter().highlight(text, as: .typescript)?.lines)
        #expect(lines[0].contains(SyntaxSpan(range: 16..<19, token: .string)))
    }

    @Test(arguments: [
        ("Sources/App.cs", SyntaxLanguage.csharp), ("web/view.tsx", .tsx), ("a.mjs", .javascript),
        ("Api.csproj", .xml), ("docker/Dockerfile", .dockerfile), ("app.Dockerfile", .dockerfile),
        ("config.yml", .yaml), ("README.md", .markdown),
    ])
    func languagesAreDetectedFromFileNames(path: String, language: SyntaxLanguage) {
        #expect(SyntaxLanguage.detect(path: path) == language)
    }

    @Test func unknownFilesArePlainText() {
        #expect(SyntaxLanguage.detect(path: "notes.txt") == nil)
        #expect(SyntaxLanguage.detect(path: "LICENSE") == nil)
        for dropped in ["main.swift", "schema.sql", "build.sh"] {
            #expect(SyntaxLanguage.detect(path: dropped) == nil)
        }
    }

    @Test func innerCapturesPaintOverOuterOnesAndTheFirstOfEqualRangesWins() {
        let text = "abcdef"
        let lines = SyntaxHighlighter.lines(
            text,
            [
                (NSRange(location: 0, length: 6), .string),
                (NSRange(location: 2, length: 2), .constant),
                (NSRange(location: 2, length: 2), .keyword),
            ])
        #expect(
            lines == [
                [
                    SyntaxSpan(range: 0..<2, token: .string),
                    SyntaxSpan(range: 2..<4, token: .constant),
                    SyntaxSpan(range: 4..<6, token: .string),
                ]
            ])
    }

    /// Generated and minified files nest expressions thousands deep.
    @Test func deeplyNestedCodeStillGetsItsDefinitions() async throws {
        let depth = 20_000
        let text =
            "const x = " + String(repeating: "(", count: depth) + "1"
            + String(repeating: ")", count: depth) + ";\nfunction later() {\n  return 1;\n}\n"
        let scopes = try #require(
            await SyntaxHighlighter().highlight(text, as: .typescript)?.scopes)
        #expect(SyntaxScope.names(around: 2, in: scopes) == ["later"])
    }
}
