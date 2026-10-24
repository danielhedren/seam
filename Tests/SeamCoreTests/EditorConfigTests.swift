import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct EditorConfigTests {
    private let config = EditorConfig(
        """
        root = true

        [*]
        indent_style = space
        indent_size = 4

        [*.{yml,yaml}]
        indent_size = 2

        [Makefile]
        indent_style = tab
        tab_width = 8

        [src/legacy/**]
        tab_width = 3
        """)

    @Test(arguments: [
        ("App.cs", 4), ("ci/build.yml", 2), ("deploy.yaml", 2), ("Makefile", 8),
        ("sub/Makefile", 8), ("src/legacy/old.c", 3), ("src/new.c", 4),
    ])
    func theLastMatchingSectionDecides(path: String, width: Int) {
        #expect(config.tabWidth(for: path) == width)
    }

    @Test func noMatchingSectionMeansNoWidth() {
        #expect(EditorConfig("[*.cs]\nindent_size = 4\n").tabWidth(for: "a.ts") == nil)
        #expect(EditorConfig("").tabWidth(for: "a.ts") == nil)
        #expect(EditorConfig("[*]\nindent_size = tab\n").tabWidth(for: "a.ts") == nil)
    }
}
