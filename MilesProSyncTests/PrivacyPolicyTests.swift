import Foundation
import Testing
@testable import MilesProSync

struct PrivacyPolicyTests {
    @Test func parsesHeadingsBulletsAndParagraphs() {
        let blocks = PolicyDocument.parse("""
        # Title

        Intro line one
        continues here.

        ## Section
        ### Sub
        - first **bold**
        - second
        Closing.
        """)
        #expect(blocks == [
            .title("Title"),
            .paragraph("Intro line one continues here."),
            .heading("Section"),
            .subheading("Sub"),
            .bullet("first **bold**"),
            .bullet("second"),
            .paragraph("Closing."),
        ])
    }

    @Test func bundledPolicyLoadsAndCoversDeletedTrips() {
        let blocks = PolicyDocument.load()
        #expect(blocks.first == .title("MilesProSync Privacy Policy"))
        #expect(blocks.contains(.heading("Deleted trips")))
        #expect(blocks.contains(.heading("Retention")))
    }
}

extension PrivacyPolicyTests {
    /// The policy's retention promise must match the code that enforces it.
    @Test func policyStatesTheEnforcedRetentionPeriod() throws {
        let url = try #require(Bundle.main.url(forResource: "PRIVACY", withExtension: "md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(TripRetention.years == 4)
        #expect(text.contains("four years from the date of each trip"))
        #expect(text.contains("Settings → Website Sync → Delete Website Account"))
        #expect(text.contains("sign in with Apple") || text.contains("Sign in with Apple"))
    }
}
