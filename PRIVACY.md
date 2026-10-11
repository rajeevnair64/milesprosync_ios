# Miles Pro Sync Privacy Policy

Effective date: September 29, 2026

This policy explains what information MilesProSync (the "app") collects, how it is used, where it is stored, and the choices you have. The app is operated by AisleWeb ("we", "us"). If you have questions, contact us at admin@aisleweb.com.

## Summary

- The app records your location while you drive so it can log trips and calculate mileage automatically.
- You do not need an account to use the app. Your trips and settings are stored on your device.
- Website Sync is optional. Only if you turn it on by signing in with Apple are your trips (including their GPS routes) uploaded to our cloud database, so you can view them on the MilesProSync website.
- When you delete a trip, it is hidden from you but kept as a record on your device and in our cloud database.
- We do not sell your data, show ads, use third-party analytics, or track you across other companies' apps and websites.

## Information we collect

### Location

To detect drives and measure mileage, the app uses your device's location:

- **While you are not driving**, the app uses iOS "significant location change" monitoring, which reports only approximate changes in position (typically when you have moved several hundred meters), and a small region (about 100 meters) around the place you last stopped, so it notices when you drive away. While a drive is being recorded, a similar region follows your position so the app can resume recording promptly if iOS has to restart it. These regions are kept on your device and are not uploaded.
- **When a drive is detected**, the app switches to precise GPS for the duration of the drive and records a route point every 5 seconds or 20 meters, whichever comes first. Each route point contains latitude, longitude, time, and, when available, speed and accuracy.
- Location is collected in the background, including when the app is closed, if you grant "Always" location access. You can change this at any time in iOS Settings → Privacy & Security → Location Services → MilesProSync. Without location access the app cannot record trips.

### Motion activity

The app reads iOS motion activity (for example, whether the device appears to be in a vehicle) to help decide when a drive starts and ends. Motion activity is used on your device only at the moment it is read. It is not stored and is never uploaded.

### Trip records

For each drive, the app creates a trip record containing:

- start and end date and time
- start and end coordinates, and the full GPS route described above
- distance driven
- start and end street addresses (see "Address lookup" below)
- the classification you choose (Business, Personal, or Unclassified) and any notes
- whether and when you deleted the trip

Trip records are kept for four years from the date of the trip. See "Retention" below.

### Account information (optional Website Sync)

The app works without an account. If you want to view your trips on the MilesProSync website, you can turn on Website Sync in Settings by signing in with Apple. Before you sign in, the app shows exactly what will be shared (Settings → Website Sync → What's Shared).

If you sign in, we receive from Sign in with Apple a unique identifier for your Apple ID in this app and your email address. If you choose "Hide My Email", we receive a private relay address from Apple instead of your real one. We do not request your name, and we never receive your Apple ID password.

While Website Sync is on, the app stores your Apple ID identifier and a cloud sign-in token in the iOS Keychain on your device, so it can keep uploading trips in the background. When you turn on Website Sync, trips already on your device are uploaded, including deleted trips kept as a record (see "Deleted trips"). Trips still in progress are never uploaded.

### Settings

Your country and reimbursement rate are stored only on your device and are not uploaded.

### Website

If you sign in on the MilesProSync website, it receives the same Sign in with Apple information described above and shows the trips uploaded by Website Sync. The website only displays your trips; it cannot change them.

The website uses only these cookies, all needed for it to work. There are no advertising or analytics cookies.

- a sign-in cookie holding your sign-in session, signed so it can't be altered, which ends when you sign out or after 30 days
- a security cookie that protects the website's forms
- your time zone, so trip times show in your local time
- your reimbursement rate and currency symbol, only if you change them on the website

Route drawings on the website are made in your browser from your own trip data; no map service receives your trip locations.

## How we use information

We use the information above only to provide the app's features:

- detecting drives and recording trips
- calculating mileage and reimbursement amounts
- showing your trips and producing the CSV, PDF, and Excel exports you request
- if you turn on Website Sync: signing you in, and uploading your trips so you can view them on the website
- keeping a complete record of trips, including trips you have deleted (see "Deleted trips")

We do not use your information for advertising, profiling, or any purpose unrelated to these features.

## Deleted trips

When you delete a trip, it is removed from your trip list and from exports, and you cannot view it again in the app. The trip record is **not erased** straight away: it is kept on your device and, if you use Website Sync, in our cloud database with the time it was deleted, until four years after the date of the trip. We keep these records so there is a complete history of recorded trips for tax and audit record-keeping. See "Retention" below.

## Sharing and service providers

We do not sell or rent your information, and we do not share it with third parties for their own purposes. The app relies on these service providers:

- **Apple (address lookup).** When a trip ends, the app sends its start and end coordinates to Apple's geocoding service to look up street addresses. Apple's handling of this data is described in Apple's privacy policy.
- **Apple (Sign in with Apple, only if you turn on Website Sync).** Apple authenticates you and tells us your Apple ID identifier and, if you share it, your email address. Apple's handling of this is described in Apple's privacy policy.
- **jsDelivr (website only).** The website loads its Bootstrap code and style files from jsDelivr, a public content delivery network, which receives your IP address and browser information when delivering them.
- **DigitalOcean (Website Sync, only if you turn it on).** Our website server and database, which hold your account and trip records, are hosted by DigitalOcean in the eastern United States. DigitalOcean processes this data on our behalf.

We may also disclose information if required by law, or to protect the rights and safety of our users or others.

## Exports you share

Exports (CSV, PDF, Excel) are created on your device and include trip dates, addresses, distances, classifications, and reimbursement amounts. When you share an export, for example by email or AirDrop, the recipient receives that information. We do not see or control exports you share.

## Storage and security

- Trip records on your device are stored in the app's private storage and protected by iOS data protection.
- Uploads by Website Sync use encrypted connections (HTTPS), and our server's connection to the database is encrypted too.
- The app never connects to the database directly. Our server checks your Sign in with Apple identity and lets a signed-in user read and write only their own trips. Users cannot permanently remove trip records.
- No method of storage or transmission is completely secure, but we take reasonable measures to protect your information.

## Retention

We keep trip records for **four years from the date of each trip** for tax and audit record-keeping, and then permanently erase them.

- **On your device**, trips you have deleted are erased once they are four years old. Trips still in your trip list stay until you delete them. Turning off Website Sync keeps your trips and settings on the device. Removing the app erases all of its data from the device, including your sign-in.
- **In the cloud** (only if you used Website Sync), every trip record, including deleted trips, is erased four years after the date of the trip. This applies even if you delete your account: deleting your account removes your cloud login and email address, but trip records already uploaded are kept until they reach four years old.
- **Account information** (your email address and login) is kept until you delete your website account.

## Your choices and rights

- **Location and motion access:** you can turn these off at any time in iOS Settings. The app will stop recording trips.
- **Website Sync is optional:** leave it off and nothing is uploaded. If you turn it on, Settings → Website Sync → Turn Off Website Sync stops uploads at any time. Trips keep recording on your device.
- **Stopping Sign in with Apple:** you can stop using Sign in with Apple for the app in iOS Settings → your name → Sign-In & Security → Sign in with Apple. The app then turns off Website Sync.
- **Access and copies:** you can export your trips at any time from the app.
- **Correction:** you can change a trip's classification in the app.
- **Account deletion:** you can delete your website account in the app under Settings → Website Sync → Delete Website Account, or on the website's Account page. This removes your cloud login and email address immediately and turns off Website Sync; uploaded trip records are kept until four years after each trip's date, as described in "Retention", then erased. You can also contact us at admin@aisleweb.com.
- Depending on where you live (for example, the European Economic Area, the United Kingdom, or California), you may have additional rights, such as to access, correct, delete, or port your personal information, or to object to or restrict certain processing. To exercise them, contact us at admin@aisleweb.com. We will respond within the time required by applicable law.

## Children

The app is not directed to children under 13 (or the minimum age in your country), and we do not knowingly collect their information. If you believe a child has provided us information, contact us and we will delete it.

## Changes to this policy

We may update this policy from time to time. We will change the effective date above and, for significant changes, notify you in the app.

## Contact

AisleWeb
admin@aisleweb.com
