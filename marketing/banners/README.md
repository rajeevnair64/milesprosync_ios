# Web banners

Styling is taken from the app (`AppTheme.swift`, asset colors): blue-to-teal gradient (#244DBA to #0A576B),
gold accent #FFD36E, teal #62D8CF, ink #14243B, and the app icon. The public website was not reachable
from the build environment, so these are **inspired by the app**; compare against the live site and adjust
the colors/fonts in `build.py` if they differ.

| File | Size | Use |
|---|---|---|
| leaderboard-728x90 | 728x90 | Top/bottom of page |
| mobile-320x50 | 320x50 | Mobile banner |
| medium-rectangle-300x250 | 300x250 | In-content, sidebar |
| large-rectangle-336x280 | 336x280 | In-content |
| half-page-300x600 | 300x600 | Sidebar |
| wide-skyscraper-160x600 | 160x600 | Sidebar |
| billboard-970x250 | 970x250 | Header |
| social-1200x628 | 1200x628 | Social share / Open Graph |

Each has an `.html` source and a `@2x.png` render. Regenerate: `python3 build.py && node render.js`.
Replace the placeholder button with Apple's official App Store badge before publishing. Copy and price
match `app-store/listing.md`.
