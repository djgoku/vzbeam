import Testing
@testable import VzCore

@Test func testValueBooleanPairPositional() {
    let a = Args(["run", "--mac", "5e:1", "--headless", "--share", "tag", "/p"],
                 booleanFlags: ["headless"], pairFlags: ["share"])
    #expect(a.positionals == ["run"])
    #expect(a.value("mac") == "5e:1")
    #expect(a.has("headless"))
    #expect(a.pair("share")?.0 == "tag")
    #expect(a.pair("share")?.1 == "/p")
}
