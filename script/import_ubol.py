#!/usr/bin/env python3
"""Import a reviewed uBOL checkout and PSL snapshot; never executes upstream JS.

Usage: python3 script/import_ubol.py CHECKOUT PUBLIC_SUFFIX_LIST
The app loads only generated data. Updating filters is an explicit maintainer step.
"""
import collections
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
LISTS = ['ublock-filters', 'easylist', 'easyprivacy', 'pgl', 'ublock-badware', 'urlhaus-full']
CONDITIONS = {'urlFilter', 'isUrlFilterCaseSensitive', 'requestDomains', 'excludedRequestDomains',
              'initiatorDomains', 'excludedInitiatorDomains', 'resourceTypes', 'excludedResourceTypes',
              'requestMethods', 'excludedRequestMethods', 'domainType'}


def js_data(source, name, is_map=False):
    # These upstream declarations contain JSON literals, not executable expressions.
    start = re.search(r'const ' + name + r' = (?:new Map\()?\s*(?:/\*.*?\*/\s*)?', source)
    if not start:
        raise ValueError('Missing upstream data: ' + name)
    value, end = json.JSONDecoder().raw_decode(source[start.end():])
    assert source[start.end()+end:].startswith(');' if is_map else ';')
    return value


def main():
    checkout, psl = map(pathlib.Path, sys.argv[1:])
    upstream = checkout/'chromium'
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    out = ROOT/'resources/ContentBlocking'
    out.mkdir(parents=True, exist_ok=True)
    rules, generic, specific, exceptions = [], set(), {}, {}
    counts, sources = {}, []
    def add(target, host, values):
        target.setdefault(host, set()).update(values)
    for name in LISTS:
        skipped = collections.Counter()
        accepted = 0
        for category in ['main', 'regex']:
            path = upstream/f'rulesets/{category}/{name}.json'
            if not path.exists():
                continue
            sources.append(path)
            for rule in json.loads(path.read_text()):
                if rule['action']['type'] not in ['block', 'allow']:
                    skipped[rule['action']['type']] += 1
                elif set(rule['condition']) - CONDITIONS:
                    skipped['unsupported condition'] += 1
                else:
                    rules.append(rule)
                    accepted += 1
        procedural = 0
        path = upstream/f'rulesets/scripting/specific/{name}.json'
        if path.exists():
            sources.append(path)
            data = json.loads(path.read_text())
            for host, ref in zip(data['hostnames'], data['selectorListRefs']):
                for index in map(int, data['selectorLists'][ref].split(',')):
                    selector = data['selectors'][index if index >= 0 else ~index]
                    if selector.startswith('{'):
                        procedural += 1
                        continue
                    add(specific if index >= 0 else exceptions, host, [selector])
            skipped['cosmetic hostname regexes'] = len(data['regexes']) // 3
        path = upstream/f'rulesets/scripting/generic/{name}.js'
        if path.exists():
            sources.append(path)
            source = path.read_text()
            for _, selectors in js_data(source, 'lowlyGeneric', True):
                generic.update(selectors.split(',\n'))
            generic.update(js_data(source, 'highlyGeneric').split(',\n'))
            for host, selectors in zip(js_data(source, 'hostnames'), js_data(source, 'exceptions')):
                add(exceptions, host, selectors.split('\n'))
        counts[name] = {'networkRules': accepted, 'skipped': dict(skipped),
                        'skippedProceduralAssociations': procedural}
    def write(name, data):
        (out/name).write_text(json.dumps(data, ensure_ascii=True, separators=(',', ':'))+'\n')
    write('network.json', rules)
    write('cosmetic.json', {'generic': sorted(generic - {''}),
                           'specific': {k: sorted(v) for k,v in sorted(specific.items())},
                           'exceptions': {k: sorted(v) for k,v in sorted(exceptions.items())}})
    shutil.copyfile(psl, out/'public_suffix_list.dat')
    # ASCII form lets the native matcher operate on Chromium's punycode hostnames.
    suffixes = [line.strip().encode('idna').decode('ascii') for line in psl.read_text().splitlines()
                if line.strip() and not line.startswith('//')]
    (out/'suffixes.txt').write_text('\n'.join(suffixes)+'\n')
    shutil.copyfile(checkout/'LICENSE', out/'COPYING-uBOL.txt')
    sources += [upstream/'rulesets/ruleset-details.json', upstream/'manifest.json', checkout/'LICENSE']
    with tarfile.open(out/'upstream-source.tar.xz', 'w:xz') as archive:
        for path in sorted(sources):
            info = archive.gettarinfo(str(path), arcname=str(path.relative_to(checkout)))
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            with path.open('rb') as stream:
                archive.addfile(info, stream)
    write('provenance.json', {
        'project': 'uBlock Origin Lite', 'source': 'https://github.com/uBlockOrigin/uBOL-home',
        'revision': revision, 'version': json.loads((upstream/'manifest.json').read_text())['version'],
        'publicSuffixSource': 'https://publicsuffix.org/list/public_suffix_list.dat',
        'rulesets': counts, 'networkRules': len(rules), 'genericSelectors': len(generic - {''}),
        'sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir())
                   if p.name != 'provenance.json' and p.is_file()}})
    print(json.dumps(counts, indent=2))
    print(f'Imported {len(rules)} network rules at {revision}')


if __name__ == '__main__':
    main()
