# Arc Sidebar migration

Lite discovers `StorableSidebar.json` under Arc's usual Application Support
directory and its sandbox-container equivalent, with bounded traversal for
additional local containers. First launch offers a preview or Start Fresh.
Settings → Import Sidebar from Arc supports manual JSON selection at any time.

## Read-only pipeline

1. Read the source file without modifying it.
2. Select a recognized sidebar container or sync-state schema.
3. Decode dictionaries or Swift Codable alternating key/value arrays by field
   names and discriminators, never a fixed root-array offset.
4. Traverse pinned containers and Favorites through ordered child IDs.
5. Validate unique IDs, existing references, folder cycles, parent relationships,
   supported URLs, and Space ordering.
6. Build a separate in-memory Lite model with new UUIDs.
7. Show counts and warnings. Only an accepted preview merges the result in one
   SQLite transaction. Cancellation or failure leaves Lite organization unchanged.

Imported Spaces stay distinct. Nested folders remain nested. Both siblings and
Favorites retain order. A custom tab name takes precedence over the saved page
title. Internal item containers are traversed without becoming artificial folders.
Arc split groups are preserved as folders of pages, with a preview warning.
Missing/unsupported URLs are skipped and counted in warnings. Missing references,
duplicate IDs, and cycles fail the entire preview rather than silently dropping
branches. The parser has a 64 MB input limit.

Arc source files, profiles, records, cookies, account data, and assets are never
written, moved, or deleted. Cookies and passwords are not migrated. Lite does not
make network requests to populate the preview, and never automatically opens all
imported URLs. Favicons are regenerated only when pages are opened.

## Coverage and limitations

Sanitized fixtures in `lite/tests/fixtures` cover compact records, current-style
Codable containers, and wrapped sync dictionaries. Tests also exercise multiple
containers, same source IDs in separate containers, Unicode names, nested folders,
malformed JSON, missing references, duplicate IDs, empty profiles, and 2,000 pins.
Fixtures are synthetic; no real personal browsing data belongs in this repository.

Unknown Arc schemas fail with an explanation and manual-selection/bookmark-import
alternatives. No parser can promise compatibility with future unpublished schemas.
Where an object dictionary supplies no explicit Space ordering, its keys are sorted
for deterministic fallback; an available `orderedSpaceIDs` array takes precedence.

Ordinary HTML, Chromium JSON, and Safari plist bookmarks use a separate importer
and are placed under an Imported Bookmarks folder. Safari access may require a
user-selected export or macOS permission; Lite does not bypass those permissions.
