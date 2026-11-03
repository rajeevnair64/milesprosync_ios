# App Store listing copy (draft for review)

Prices and the trial come from `MilesProSync/Subscription/AccessPolicy.swift`: $4.99/month, $39.99/year,
one-day free trial, Team $3.99/user/month ($34.99/user/year), one-time $109.99 for five years.
Note: the app has **no permanent free tier**, so copy must not say "free" or "no cap" beyond the trial.
Re-verify every claim against the shipping build before submitting. Limits are Apple's.

## Metadata
| Field | Limit | Text | Length |
|---|---|---|---|
| Name | 30 | Miles Pro Sync: Mileage Log | 27 |
| Subtitle | 30 | Auto Tax Mileage Tracker | 24 |
| Promotional text | 170 | Every drive logged automatically. Repeat routes classify themselves, so your mileage log is tax-ready without the swiping. Try it free for a day. | 145 |
| Keywords | 100 | `irs,business,drive,trip,gps,deduction,expense,self employed,rideshare,driver,reimbursement,miles` | 96 |
| Category | | Primary: Business. Secondary: Finance (or Productivity). | |

## Description (under 4,000 characters)

Miles Pro Sync logs every drive for you, so your mileage log is ready at tax time without lifting a finger.

STOP TYPING, STOP SWIPING
The app notices when you start and finish a drive and records it in the background. Drive the same route
again and it classifies itself using the choice you made last time. Business trips stay Business,
personal trips stay Personal, and you only step in when something is new.

BUILT FOR REAL LIFE
• Automatic drive detection with route, distance, start and end addresses
• Repeat routes take the classification you last chose
• Saved places and work hours classify more trips for you
• Add or edit a trip by hand when you need to
• Add a purpose and notes to each drive, such as "Client visit"
• Swipe through unclassified trips in a quick review screen

TAX-READY EXPORTS
• Export your log as PDF, CSV or Excel
• Estimated reimbursement using IRS mileage rates, or your own rates and FAVR settings
• Filter by date and classification before you export

FOR INDIVIDUALS AND TEAMS
• Individual plan for one driver
• Team plan per user, with a shared view for the people you manage
• Sign in with Apple and sync your trips to the Miles Pro Sync website

PRIVATE BY DESIGN
Your trips are stored on your device. Syncing to the website is optional. Read the privacy policy in the
app and on our website.

PRICING
Try everything free for one day. After the trial:
• Individual: $4.99 per month or $39.99 per year
• Team: $3.99 per user per month or $34.99 per user per year
• Individual pay-once option: $109.99 for five years, no renewals

Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current
period. Manage or cancel in your Apple ID settings.

Location access: choose "Always" so drives are detected when the app is closed. Continuous use of GPS in
the background can reduce battery life.

Miles Pro Sync provides mileage estimates and is not tax advice. Check current IRS rules or talk to a tax
professional.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

## What's New (1.0)
Welcome to Miles Pro Sync. Automatic drive logging, repeat routes that classify themselves, and tax-ready
PDF, CSV and Excel exports.

## Screenshot captions (five, benefit-led)
1. Every drive logged automatically
2. Repeat routes classify themselves
3. Business or personal in one swipe
4. Tax-ready PDF, CSV and Excel
5. Built for teams, private by design

## Preview video (15-30 s) storyboard
Drive ends, notification, trip appears (3 s) → same route again, already classified Business (5 s) →
review screen swipe (4 s) → export to PDF (4 s) → end card with price and trial (3 s).

## App Review notes (paste into App Store Connect)
Background location is the core function: the app detects drives while closed and records the route.
Demo account: <add credentials>. To test, start the Xcode/TestFlight build, allow "Always" location, and
use Simulator > Features > Freeway Drive. Subscriptions are the Apple in-app purchases listed in the
Subscriptions section.

## A/B tests to run (Product Page Optimization)
- Icon: current vs. a version with a route line
- First screenshot: "Every drive logged automatically" vs. "Never swipe the same route twice"
- Subtitle: "Auto Tax Mileage Tracker" vs. "Mileage Log & Tax Deduction"

## Open items before submitting
- The website URL and support/marketing URLs are not in the repo; add them.
- Confirm the Team "shared view" and export formats wording against the build.
- Confirm trademark clearance for "Miles Pro Sync".
- Use Apple's official "Download on the App Store" badge in production banners (the buttons here are placeholders).
