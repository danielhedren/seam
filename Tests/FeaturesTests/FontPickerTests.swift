import Testing

@testable import Features

@MainActor @Suite(.timeLimit(.minutes(1))) struct FontPickerTests {
    @Test func fontPickerListsFixedPitchFamiliesAndKeepsAnUnlistedChoice() {
        let fonts = MonospacedFont.installed(keeping: "Some-Missing-Font")

        #expect(fonts.contains { $0.family == "Menlo" && $0.name == "Menlo-Regular" })
        #expect(!fonts.contains { $0.family == "Helvetica" })
        #expect(fonts.contains { $0.name == "Some-Missing-Font" })
        #expect(!MonospacedFont.installed(keeping: "").contains { $0.name.isEmpty })
    }
}
