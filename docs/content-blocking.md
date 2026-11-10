# Native content blocking

Lite uses locally bundled data from [uBlock Origin Lite](https://github.com/uBlockOrigin/uBOL-home),
without installing an extension or changing the CEF Alloy/native-sidebar architecture.
The sidebar shield, **View → Content Blocking**, **Settings → Content blocking**,
and the Command Bar open the same controls.

Blocking and cosmetic hiding are enabled by default. The shield shows a snapshot of
blocked requests for the current navigation. Pause a particular hostname, turn off
cosmetic hiding independently, or disable filtering globally. Apply reloads the
selected page; reload other open pages to update their existing styles. Preferences
persist in the regular SQLite profile. Private-window preferences remain in memory
and do not change the regular profile. Pausing a hostname covers its page and embedded
resources; it does not automatically pause other subdomains.

## Included behavior

- 17,665 supported `block`/`allow` rules from the pinned default uBlock, EasyList,
  EasyPrivacy, Peter Lowe, uBlock Badware, and URLhaus rulesets.
- DNR URL wildcards, domain/start/end anchors, separators, case sensitivity,
  request/initiator domain inclusions and exclusions, request methods, resource
  types, priorities, and allow-rule precedence at equal priority.
- First/third-party classification using a bundled Public Suffix List, including
  private suffixes and wildcard/exception entries.
- Local custom network filters with URL patterns and allow exceptions, edited from
  **Content Blocking → Custom Filters…**. They remain in effect when bundled or
  downloaded filters are replaced. See [custom network filters](#custom-network-filters).
- Generic and hostname/entity-specific CSS selectors with cosmetic exceptions;
  constructed stylesheets apply to dynamically added elements and respect site
  pause settings. No upstream JavaScript runs inside a page.
- CEF request interception before transmission, including redirect destinations.
  Context handlers also filter service-worker network requests without an associated
  tab, using the worker's initiating origin for the site preference. Such requests
  are not added to an arbitrary tab's counter. Responses already produced from a
  worker's own CacheStorage are outside this network layer.
- YouTube pre-roll filtering: native response filtering neutralizes the
  `adPlacements`, `adSlots`, and `playerAds` property keys in YouTube HTML and
  player/watch API responses before the page consumes them. This covers initial
  playback, Fetch/XHR responses, serialized player-response JSON, and in-page
  video changes without an extension. Video URLs and media streams are preserved.
  The global and per-site switches also control this filter; cosmetic hiding is
  independent. Reload an already-open video after enabling blocking. The shield's
  request counter counts canceled network requests, not rewritten player fields.
- A bundled YouTube player fallback handles ads that still reach the player. It
  clicks visible Skip Ad controls only while the player reports an ad. It can
  advance explicitly marked `SSAP, AD` segments, or distinct finite ad media when
  the main video's duration is known. Unknown/live media and a stale ad class on
  the main video are left alone. It observes player changes and media events,
  preserves volume/playback speed, and stops immediately when blocking is paused
  for the page, frame, or context. Disabling cosmetic hiding does not disable it.

## Deliberate limits

This is a native subset, not full uBOL parity. It does not execute upstream scriptlets,
replacement/redirect scripts, procedural cosmetic filters, regex-based network
rules, response-header conditions, or header-modification rules. Apart from the
targeted native YouTube response filter, response-body rules are unsupported. Other rules are
omitted rather than approximated; per-list counts are recorded in `provenance.json`.
Missing exceptions or anti-adblock workarounds can affect compatibility: pause the
site if it breaks. Cosmetic styles are page-level CSS, not privileged browser user
styles; pages can override/remove them, and closed shadow trees are not filtered.

There is no element picker, custom cosmetic filter editor, regional/annoyance-list
selector, dedicated popup-filter list, or strict-block interstitial. Lite's existing gesture-based popup handling remains in place.
WebSocket handshakes are not intercepted by this CEF resource hook. No claim is
made to remove all advertisements. YouTube can change its player format or deliver
ads within the video stream itself; these filters do not edit media or guarantee
removal of every server-inserted ad or anti-adblock challenge.

The YouTube field handling follows the approach documented in the upstream
[uBlock filters](https://github.com/uBlockOrigin/uAssets/blob/master/filters/filters.txt)
and [quick fixes](https://github.com/uBlockOrigin/uAssets/blob/master/filters/quick-fixes.txt),
reviewed on 2026-09-27. Lite implements its own bounded streaming adapter in
`lite/browser/LTYouTubeFilter.h` and a targeted fallback in
`resources/ContentBlocking/youtube.js`; it does not download or execute these
lists at runtime. Escaped-key rewriting requires a structural key boundary and
an object/array value; ordinary escaped mentions are preserved.

## Custom network filters

Open **Content Blocking → Custom Filters…** to enter one network filter per line.
An empty line is ignored, and a line starting with `!` is a comment. Patterns are
case-insensitive ASCII and match anywhere in the request URL unless anchored:

| Syntax | Meaning |
| --- | --- |
| `tracker.example/pixel` | Block a URL containing this text |
| `*` | Match any run of characters |
| `^` | Match a URL separator or the end of the URL |
| `|https://example.com/pixel|` | Match this complete URL |
| `||tracker.example^` | Match this hostname and its subdomains, followed by a separator or the end |
| `@@||tracker.example/needed.js|` | Allow this URL, including on subdomains |

For example:

```text
! Block this host's requests except one required script.
||tracker.example^
@@||tracker.example/needed.js|
```

The editor accepts at most 1,000 active rules, 2,048 characters per line (including
comments), and 256 KiB of UTF-8 text in total. It refuses the entire edit if any line
is invalid, reports its line number and reason, and keeps the saved filters. The
same validation applies when reading or saving a profile. Unsupported forms include
`$` options such as `$third-party` and `$domain=`, cosmetic rules such as `##`,
`#@#` and `#?#`, regular expressions, scriptlets, and replacement scripts. These
are rejected rather than treated as ordinary URL text.

A matching custom `@@` exception wins over all custom and bundled network blocks.
A matching custom block wins over bundled exceptions. Line order does not change
this precedence. Custom rules apply to subresources and subframes, including
redirect destinations and network requests made by service workers. They do not
block main-frame navigation: `||site.example^` does not prevent opening the site
itself. A custom exception affects network cancellation only; it does not turn off
cosmetic hiding or the YouTube response/player filters. The global switch and
per-hostname pause still disable custom blocking along with the built-in filters.

Applying saves the text and reloads the selected page. Regular windows share the
saved text. Each new private window copies the regular profile's current custom
filters; later edits in that private window stay in memory and affect neither the
regular profile nor other private windows. Later regular edits do not change an
already-open private window. The compiled custom rules belong to each browser
context, separately from downloaded filter sets, so installing a filter update
does not discard them.

The editor makes no network requests and never uploads the text. Bookmarks and
organization exports do not include settings, so they do not include custom filters.
Custom cosmetic filters, regular expressions, scriptlets and an element picker
remain outside this first part of the roadmap goal.

## Source, updates, and licensing

The initial data is uBOL **2026.920.1710**, revision
`ef846e7c0496a5f6769b203ee1f57e9866a76bd3`. The PSL snapshot is
`2026-09-21_18-50-07_UTC`, revision `728555a30ef4d40e42a82d5678e5fbad2ad17b26`.
The bundled GPL notice, original source inputs, upstream ruleset metadata, PSL
notice, hashes, and adapter provenance live under `resources/ContentBlocking` and
are copied into the signed app. Retain the notices and corresponding source when
distributing a build; see that directory's `NOTICE.txt` and `COPYING-uBOL.txt`.

To update, review a new upstream revision in a separate checkout, obtain the PSL
from its official URL, and run:

```sh
python3 script/import_ubol.py /path/to/ubol-checkout /path/to/public_suffix_list.dat
./script/build_and_run.sh --build
python3 script/test_browser.py
```

The converter reads JSON literals without evaluating upstream scripts. Review
coverage changes and update the pinned-count regression intentionally. The import
stamps `provenance.json` with a `serial`, the time it ran as `YYYYMMDDHHMM` in UTC.
Builds never fetch upstream lists or run upstream code; a build with a filter feed
fetches only sets you have signed, as described below.

## Filter updates

A release can take new filters without a new version of Lite. The maintainer signs a
filter set and puts it on a web server; Lite checks that server and installs a set only
if it verifies. Updates are off in any build packaged without both
`LITE_FILTER_FEED_URL` and `LITE_FILTER_PUBLIC_KEY`, including every local and test
build, so those builds never contact a feed.

**Publishing.** `script/sign_filters.py` does each step:

```sh
python3 script/sign_filters.py key ~/secure/lite-filters.pem   # once; prints LITE_FILTER_PUBLIC_KEY
python3 script/sign_filters.py serial                          # after changing any filter file
python3 script/sign_filters.py publish /path/to/feed --key ~/secure/lite-filters.pem
```

The key is a P-256 key created by `openssl`, readable only by its owner, and the
script refuses to overwrite one, because a build trusts only the key it was packaged
with. Losing it means filter updates stop until a release ships a new public key.
`publish` refuses a set whose files differ from `provenance.json`, or whose serial is
not newer than the one already in the feed directory. It writes:

| Path | Holds |
| --- | --- |
| `<serial>/` | The seven files Lite loads, plus `upstream-source.tar.xz` and the PSL for the GPL |
| `filters.json.sig` | Base64 ECDSA P-256 SHA-256 signature of `filters.json`'s exact bytes |
| `filters.json` | `format`, `version` 1, `serial`, `created`, and each file's size and SHA-256 |

Upload them in that order so a client never reads a manifest whose files are missing.
Any static HTTPS host works. Choosing it is a release decision, not yet made.

**Checking.** Lite looks 30 seconds after launch and then hourly, but asks the feed only
if 24 hours have passed since its last check, an hour since a check that failed, or when
**Check Now** is pressed in the Content Blocking sheet. It downloads the files one at a
time, so a check holds at most one connection to the feed host. **Update filters automatically** there turns scheduled checks
off; it is saved in the regular profile and cannot be changed from a private window.
Requests are GETs with no cookies, credentials or cache, `Lite-Browser` as the user
agent, and no redirects. The feed host learns the Mac's IP address and that it runs Lite,
and nothing else about the user.

**Verifying.** Lite installs a set only when all of these hold:

- `filters.json.sig` is the build's key's signature of `filters.json`. Both have size
  limits, 64 KB and 1 KB.
- The manifest's `format` is `lite-filters` and its `version` is one this build reads. A
  newer version is reported as needing a newer Lite.
- It lists exactly the seven files Lite loads, each at most 32 MB and together at most
  64 MB, and each downloaded file has the listed size and SHA-256.
- `provenance.json` carries the manifest's serial.
- The serial is larger than that of the filters in use, so a feed, or anyone replaying an
  old signed manifest, cannot roll filters back.
- The set compiles.

It is written to a staging folder under `Filters` in the profile, compiled, moved into
place and named in `Filters/current`; then older sets are deleted. Any failure leaves the
filters in use and on disk unchanged, and the sheet shows the reason.

**Applying.** The new rules replace the ones in use at once
(`+[LTContentBlocker install:]`). Every network request asks for the current rules, so
the next request uses them; open pages keep the cosmetic styles they already applied
until they reload. At launch, Lite verifies the installed set again (signature, sizes and
hashes) and uses it only if it is newer than the filters bundled with this version of
Lite. Otherwise it deletes the set, so an app update with newer bundled filters wins,
and a damaged set is replaced at the next check.

The private key is the trust anchor: anyone holding it can change what Lite blocks for
every user of that build. It never enters the repository or the app, and the script
never prints it.

## Verification

`LiteCustomFilterTests` covers the accepted grammar, hostname boundaries, exception
precedence, the input limits, whole-edit rejection, profile persistence, private
isolation, concurrent policy swaps, and keeping custom rules when the shared filter
set is replaced. Native window checks exercise the editor's controls and saved/unsaved edits. The Chromium
fixture sends requests sequentially and checks actual server hits for custom blocks,
redirect destinations, worker requests and exceptions to bundled rules, then checks
site/global pause and independent regular/private changes. These fixtures use only
loopback addresses.

`LiteFilterUpdateTests` uses real P-256 keys and serves feeds from an in-process
stand-in for the network. It covers key and feed-address parsing, each manifest
refusal, installing a set, the requests sent, refusing older sets, mismatched or
missing files, provenance mismatch, a set that does not compile, a redirect, a check
already running, launch loading and deletion of damaged or outdated sets, and
replacing the rules in use while other threads read them. Making the updater follow
redirects or skip the hash check made the matching checks fail. The native suite
signs a set with one extra rule using a key made for the run and serves it over
loopback; the running app must install it without relaunching, block the new rule,
send nine requests without cookies, and show the sheet's controls.

`LiteBlockingTests` exercises real upstream rules, URL-boundary negatives, allow
precedence, method/type/domain restrictions, PSL cases, cosmetic exceptions,
preference persistence, and private isolation. The packaged-resource test verifies
digests and license/source presence. The bundled Chromium smoke suite checks actual
network/server-hit counts, redirects, service workers, strict-CSP cosmetic hiding,
dynamic DOM elements, site/global pause, re-enabling, and private-context isolation.
Use `LITE_BLOCKING_ONLY=1 python3 script/test_browser.py` for the focused browser run.
YouTube regression fixtures run through the same Chromium response hook using a
test-process-only hostname mapping to loopback and an ephemeral HTTPS certificate
pinned only for that test process. They check filtering before the
first inline script, compressed Fetch/XHR JSON, in-page navigation, preservation
of regular content and unrelated APIs, incomplete final chunks, site/global
pause, cosmetic independence, and private-context isolation. Player fixtures also
check visible/hidden/reused skip buttons, explicit server-ad markers, finite client
ads, stale ad classes, unknown/live content, unchanged volume/speed, and immediate
pause/resume without a reload. Native tests also
exercise every input-chunk boundary and one-byte output buffers. These fixtures
verify the mechanism; they are not a substitute for live YouTube compatibility checks.
