// GENERATED at release time. The one-time export ceiling (spec §2/§4) compares
// this build's release date against the token's `updates_until`. The release
// pipeline overwrites this with the actual publish date; the checked-in value
// is the date this build was cut.
// A top-level `const DateTime` cannot call `DateTime.utc(...)` (not a const
// constructor), so this is exposed as `final` instead.
final DateTime buildReleaseDate = DateTime.utc(2026, 8, 27);
