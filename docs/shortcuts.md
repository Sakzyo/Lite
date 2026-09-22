# Keyboard shortcuts

These are the defaults. Use **View → Keyboard Shortcuts…** (also in Settings)
to record a Command/Control shortcut for a menu command, clear it, restore its
default, or reset all bindings. Conflicts are rejected; changes apply to all
windows and survive relaunch. Escape cancels recording.

| Shortcut | Action |
| --- | --- |
| ⌘T | Open Command Bar |
| ⌘L | Edit current address |
| ↑ / ↓, Return, Escape | Navigate, accept, or dismiss Command Bar |
| ⌘N / ⇧⌘N | Normal / private window |
| ⌘W / ⇧⌘T | Close / reopen tab |
| ⌘D | Pin or unpin |
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / forward |
| ⌘F | Find in page |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / reset |
| ⌘P / ⌘S | Print / save HTML |
| ⇧⌘S | Toggle sidebar |
| ⌘\\ / ⇧⌘\\ | Split right / down |
| ⌘` | Focus other split pane |
| ⌘{ / ⌘} | Previous / next Space |
| ⌥⌘[ / ⌥⌘] | Previous / next tab |
| ⌘Y / ⌘J | History / downloads |
| ⌘, | Settings |
| ⇧⌘I | Developer Tools |

When the sidebar is collapsed, move the pointer to the left edge of the window
to reveal it over the page. It hides again when the pointer leaves. Navigation
and address controls live in the sidebar, including in Mini Lite; the page has
no top toolbar or leftover sidebar divider. ⇧⌘S pins or collapses the sidebar,
and normal windows remember its width and collapsed state.
The sidebar slides in and out with a short ease-out transition; Reduce Motion
disables the animation.

When typing in the Command Bar, saved pages appear only for a complete URL or
title match (case-sensitive, with surrounding whitespace ignored). Web addresses,
including domains without a scheme, select Open address first and open directly
on Return. For ordinary text, an exact saved-page match can lead the results;
otherwise web search is first. Browser commands remain available below it.
The optional Search action always searches the literal text.

The sidebar supports arrow-key selection and native outline expansion. Context
menus expose rename, duplicate, pin, moves, Favorites, splits, and copy URL.
Drop a tab on a Space button to move it, on a folder to nest it, on the pinned
region to pin it, or on the content divider to add a split pane. Favorites can be
reordered by dragging onto another Favorite. Native menus expose commands even
when no keyboard shortcut is assigned.

Bookmark folders, including nested folders, start closed on every launch. Cached
website icons appear immediately; missing icons are fetched in the background
without opening tabs. Sites without an accessible icon retain the globe fallback.

To save a login, enter it on an HTTPS website, then choose **Library → Save Login
for This Site…**. Review the username and password and choose Save. Saving the
same username on that site updates its password. Use **Library → Fill from Apple
Keychain…** on a later visit; Lite fills the form after confirmation and does not
submit it. **Manage Saved Logins…** lists and deletes saved entries.

The fill picker also offers existing macOS Internet-password entries for the exact
HTTPS host and port. Passwords are read only after selecting an account and pressing
Fill; macOS can require authorization. Apple Passwords/iCloud vault entries are not
all exposed through this API. **Library → Open Apple Passwords** opens Apple's app
for entries unavailable to Lite; it does not import or synchronize the vault.

Passwords are stored in this Mac's Keychain, separately from the browser database.
Filling matches the exact website origin (scheme, host, and port), uses the main
page's visible login form, and skips cross-site forms and new-password fields.
Private windows do not access this store. Localhost HTTP is supported for testing.
There are no automatic save prompts, cross-frame filling, passkeys, or cloud sync.
**Open Google Password Manager** opens Google's website; it does not connect or
sync accounts with Lite. Google restricts Chrome Sync access in third-party
Chromium browsers ([Chromium announcement](https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html)).

## GitHub Live Folders

Choose **File → New GitHub Live Folder…**. Enter a username and optional
`owner/repository`, then choose authored, review-requested, assigned, or all PRs
in a repository, with an optional draft filter. A token is optional for public
results; private repositories require a GitHub token authorized for those repositories.
Tokens are stored separately in Keychain and are never included in the profile JSON.

Folders refresh on launch and every five minutes. Their context menu offers status,
manual refresh, editing, and **Stop Updating (Keep Tabs)**. Refresh failures retain
the existing contents. Closed PRs leave the folder; an already-open PR remains as
a temporary tab. Ordinary bookmarks and custom tab titles are preserved. Like other
folders, Live Folders start collapsed. Private windows do not connect to GitHub.

## Browser Task Manager and Find

Open **View → Browser Task Manager** (also in Settings or the Command Bar) to see
Chromium tasks, CPU, memory, and GPU memory, refreshed every two seconds. Column
headers sort the rows. **End Process…** confirms before terminating a killable task;
the main browser is protected. Tasks can share a process, so ending one can stop
other tabs. Reload affected pages to recover. Measurements start after the first sample.

Find stays at the bottom of the page. Its close button, the search field's cancel
button, and Escape dismiss it and return focus to the page. Deleting the query by
keyboard clears matches while keeping the bar open.
