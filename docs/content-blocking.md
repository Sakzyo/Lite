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
- Generic and hostname/entity-specific CSS selectors with cosmetic exceptions;
  constructed stylesheets apply to dynamically added elements and respect site
  pause settings. No upstream JavaScript runs inside a page.
- CEF request interception before transmission, including redirect destinations.
  Context handlers also filter service-worker network requests without an associated
  tab, using the worker's initiating origin for the site preference. Such requests
  are not added to an arbitrary tab's counter. Responses already produced from a
  worker's own CacheStorage are outside this network layer.

## Deliberate limits

This is a native subset, not full uBOL parity. It does not execute scriptlets,
replacement/redirect scripts, procedural cosmetic filters, regex-based network
rules, response-header conditions, or header-modification rules. These rules are
omitted rather than approximated; per-list counts are recorded in `provenance.json`.
Missing exceptions or anti-adblock workarounds can affect compatibility: pause the
site if it breaks. Cosmetic styles are page-level CSS, not privileged browser user
styles; pages can override/remove them, and closed shadow trees are not filtered.

There is no element picker, user-authored filter editor, regional/annoyance-list
selector, dedicated popup-filter list, strict-block interstitial, or automatic
filter updater. Lite's existing gesture-based popup handling remains in place.
WebSocket handshakes are not intercepted by this CEF resource hook. No claim is
made to remove all advertisements, including first-party or video ads.

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
coverage changes and update the pinned-count regression intentionally. Builds and
normal browsing do not fetch lists or contact a filtering service.

## Verification

`LiteBlockingTests` exercises real upstream rules, URL-boundary negatives, allow
precedence, method/type/domain restrictions, PSL cases, cosmetic exceptions,
preference persistence, and private isolation. The packaged-resource test verifies
digests and license/source presence. The bundled Chromium smoke suite checks actual
network/server-hit counts, redirects, service workers, strict-CSP cosmetic hiding,
dynamic DOM elements, site/global pause, re-enabling, and private-context isolation.
Use `LITE_BLOCKING_ONLY=1 python3 script/test_browser.py` for the focused browser run.
