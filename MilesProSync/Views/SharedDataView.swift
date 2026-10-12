import SwiftUI

/// Everything website sync uploads, and what it never does. Must stay in line with `TripPayload`,
/// `AppSession.prepare` (which Apple ID details are requested) and PRIVACY.md.
struct SharedDataView: View {
    var body: some View {
        List {
            SharedDataSections()
            Section {
                NavigationLink("Privacy Policy") { PrivacyPolicyView() }
            }
        }
        .brandedBackground()
        .navigationTitle("What's Shared")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SharedDataSections: View {
    var body: some View {
        Section("From your Apple ID") {
            item("person.badge.key", "A private identifier for your Apple ID, unique to this app. It isn't your Apple ID itself.")
            item("envelope", "Your email address, or an Apple private relay address if you choose Hide My Email.")
            item("hand.raised", "Never your name, your Apple ID password, or anything else from your Apple account.")
        }
        Section("For every trip") {
            item("calendar", "Start and end date and time")
            item("road.lanes", "Distance driven")
            item("mappin.and.ellipse", "Start and end location (coordinates) and street addresses")
            item("point.topleft.down.to.point.bottomright.curvepath", "The full GPS route: a point about every 5 seconds or 20 meters, each with position, time, speed and GPS accuracy")
            item("tag", "Classification (Business, Personal or Unclassified) and whether you set it yourself")
            item("note.text", "Your notes")
            item("trash", "A trip ID, and when you deleted the trip, if you did")
        }
        Section("When it's uploaded") {
            item("icloud.and.arrow.up", "Trips already on this iPhone upload when you turn website sync on, including trips you've deleted, which are kept as a record.")
            item("arrow.triangle.2.circlepath", "After that, each trip uploads when it finishes and again when you edit or delete it.")
            item("lock", "Uploads are encrypted in transit and stored in our database, hosted by DigitalOcean. Only your account can read your trips.")
        }
        Section("Never uploaded") {
            item("xmark.circle", "Trips still in progress, your country and reimbursement rate, motion activity, and your location while you're not driving.")
        }
        Section("How long it's kept") {
            item("clock", "Uploaded trip records are kept for four years from the date of each trip, then erased, even if you turn off website sync or delete your website account.")
            item("person.crop.circle.badge.xmark", "Deleting your website account in Settings removes your login and email address right away.")
        }
    }

    private func item(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
    }
}

#Preview {
    NavigationStack { SharedDataView() }
}
