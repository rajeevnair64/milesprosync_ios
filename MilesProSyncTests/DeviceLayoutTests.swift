import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import MilesProSync

/// Layout checks that depend on the device the suite runs on. `scripts/test-all-devices.sh`
/// runs the whole suite on every supported iPhone model; each run hosts the app's screens at that
/// device's real screen size and checks they fit, including at the largest Dynamic Type sizes.
@MainActor
struct DeviceLayoutTests {
    private let screen = UIScreen.main.bounds.size

    private struct Fixture {
        let container: ModelContainer
        let trip: Trip
        let session: AppSession
        let sync: TripSyncService
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        PreviewData.insertTrips(into: container.mainContext)
        let trip = try #require(try container.mainContext.fetch(FetchDescriptor<Trip>()).first)
        return Fixture(
            container: container, trip: trip, session: .preview(),
            sync: TripSyncService(container: container, client: nil)
        )
    }

    /// Lays `view` out at the device's screen width and returns the size it asks for.
    private func fittedSize<V: View>(of view: V, typeSize: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.dynamicTypeSize(typeSize))
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: screen.width, height: .greatestFiniteMagnitude))
    }

    private func expectFits<V: View>(_ name: String, _ view: V) {
        for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let size = fittedSize(of: view, typeSize: typeSize)
            #expect(
                size.width <= screen.width + 0.5,
                "\(name) is \(size.width)pt wide on a \(screen.width)pt screen at \(typeSize)"
            )
            #expect(size.height > 0, "\(name) rendered empty at \(typeSize)")
        }
    }

    @Test func runsOnAnIPhoneSizedScreen() {
        #expect(UIDevice.current.userInterfaceIdiom == .phone)
        // Narrowest supported iPhone (14, 15, 16, 17, 18 and 19 families) is 375pt; widest is 440pt.
        #expect((375...450).contains(screen.width), "Unexpected screen width \(screen.width)")
        #expect(screen.height > screen.width)
    }

    @Test func tripListFits() throws {
        let f = try makeFixture()
        expectFits("Trip list", TripListView()
            .modelContainer(f.container).environment(f.sync).environment(f.session))
    }

    @Test func tripDetailFits() throws {
        let f = try makeFixture()
        expectFits("Trip detail", NavigationStack { TripDetailView(trip: f.trip) }
            .modelContainer(f.container).environment(f.sync).environment(f.session))
    }

    @Test func exportFits() throws {
        let f = try makeFixture()
        let trips = try f.container.mainContext.fetch(FetchDescriptor<Trip>())
        expectFits("Export", ExportView(trips: trips)
            .modelContainer(f.container).environment(f.sync).environment(f.session))
    }

    @Test func settingsFits() throws {
        let f = try makeFixture()
        expectFits("Settings", SettingsView()
            .modelContainer(f.container).environment(f.sync).environment(f.session))
    }

    @Test func websiteSyncSetupFits() throws {
        let f = try makeFixture()
        expectFits("Website sync setup", WebsiteSyncSetupView().environment(f.session))
    }

    @Test func privacyPolicyFits() {
        expectFits("Privacy policy", NavigationStack { PrivacyPolicyView() })
    }

    @Test func pdfIsLetterSizeRegardlessOfDevice() throws {
        let f = try makeFixture()
        let trips = try f.container.mainContext.fetch(FetchDescriptor<Trip>())
        let filter = ExportFilter(monthContaining: trips[0].startDate)
        let url = try PDFExporter.export(
            trips: trips, filter: filter, rate: AppSettings.reimbursementRate(perMile: 0.725, countryCode: "US")
        )
        let page = try #require(PDFDocumentPage.firstPageSize(of: url))
        #expect(page == CGSize(width: 612, height: 792))
    }
}

import PDFKit

private enum PDFDocumentPage {
    static func firstPageSize(of url: URL) -> CGSize? {
        PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox).size
    }
}
