import Foundation
import Testing
@testable import MilesProSync

struct VersionTextTests {
    @Test func appBundleReportsVersionAndBuild() {
        let text = AppSettings.versionText()
        #expect(!text.contains("?"))
        #expect(text.contains("("))
    }
}
