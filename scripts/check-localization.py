#!/usr/bin/env python3
"""Validate native resources; --runtime also tests Foundation in isolated child processes."""
import argparse
import collections
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ('en', 'de', 'fr', 'it', 'es')
RESOURCES = ROOT / 'Sources/Shared/Resources'


def scan(s):
    i=0
    while i<len(s):
        if s.startswith('//',i):
            i=s.find('\n',i) if '\n' in s[i:] else len(s);continue
        if s.startswith('/*',i):
            j=s.find('*/',i+2);i=j+2 if j>=0 else len(s);continue
        if s[i]=='"' and not s.startswith('"""',i):
            a=i;i+=1;parts=[];exprs=[];p=i
            while i<len(s):
                if s.startswith('\\(',i):
                    parts.append(s[p:i]);b=i+2;i=b;depth=1
                    while i<len(s) and depth:
                        if s[i]=='"':
                            i+=1
                            while i<len(s) and s[i]!='"': i+=2 if s[i]=='\\' else 1
                        elif s[i]=='(':depth+=1
                        elif s[i]==')':depth-=1
                        i+=1
                    exprs.append(s[b:i-1]);parts.append('%@');p=i
                elif s[i]=='\\':i+=2
                elif s[i]=='"':
                    parts.append(s[p:i]);i+=1
                    yield a,i,''.join(parts),exprs
                    break
                else:i+=1
        else:i+=1


def read_strings(path):
    # Detect duplicate keys before plutil silently collapses them.
    pairs = re.findall(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$', path.read_text(), re.M)
    keys = [json.loads(key) for key, _ in pairs]
    assert len(keys) == len(set(keys)), f'Duplicate keys: {path}'
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True)
    values = json.loads(result.stdout)
    assert len(values) == len(pairs), f'Unparsed strings: {path}'
    return values


def placeholders(value):
    return collections.Counter(re.findall(r'%(?:\d+\$)?(?:@|\d*\.?\d*[dfus]|lld|ld)', value))


def check():
    tables = {language: read_strings(RESOURCES / f'{language}.lproj/Localizable.strings') for language in LANGUAGES}
    plurals = {language: plistlib.loads((RESOURCES / f'{language}.lproj/Localizable.stringsdict').read_bytes()) for language in LANGUAGES}
    english = tables['en']
    for language in LANGUAGES:
        assert tables[language].keys() == english.keys(), f'Incomplete keys: {language}'
        assert plurals[language].keys() == plurals['en'].keys(), f'Incomplete plurals: {language}'
        for key, value in tables[language].items():
            assert value.strip(), f'Empty translation: {language}: {key}'
            assert placeholders(value) == placeholders(key), f'Placeholders: {language}: {key}'
        for key, entry in plurals[language].items():
            assert entry['NSStringLocalizedFormatKey'] == '%#@count@'
            rule = entry['count']
            assert rule['NSStringFormatSpecTypeKey'] == 'NSStringPluralRuleType'
            assert rule['NSStringFormatValueTypeKey'] == 'd'
            assert {'one', 'other'} <= rule.keys()
            for category in ('one', 'other', 'many'):
                if category in rule:
                    expected = collections.Counter({'%d': 1})
                    assert placeholders(rule[category]) == expected, (language, key, category)
    assert all(key == value for key, value in english.items()), 'English fallback must be explicit'
    all_keys = set(english) | set(plurals['en'])
    for source in (ROOT / 'Sources').rglob('*.swift'):
        text = source.read_text()
        for call in re.finditer(r'\b(L|LCount)\("((?:\\.|[^"\\])*)"', text):
            key = json.loads('"' + call[2] + '"')
            assert key in all_keys, f'Missing resource: {source}: {key}'
            assert '\\(' not in key, f'Interpolated key: {source}: {key}'
        assert 'AppleLanguages' not in text and 'AppleLocale' not in text, f'Locale override: {source}'
        assert not re.search(r'\.environment\(\s*\\\.locale', text), f'Locale environment override: {source}'
        # Direct UI literal guard. Brand, code-like content, numbers and units need no translation.
        for start, end, key, arguments in scan(text):
            if not re.search(r'\b(?:Text|Label|Button|Toggle|Picker|Section|ProgressView|ContentUnavailableView)\(\s*$', text[max(0, start - 40):start]):
                continue
            if not re.search(r'[A-Za-z]', key):
                continue
            allowed = {'Nocturne', '~ / workspace', 'HDR', 'HEVC', 'H.264', '4K'}
            assert key in allowed or key.startswith(('https://', 'http://')) or re.fullmatch(r'\d+(?:p| fps)', key), f'Unlocalized UI literal: {source}: {key}'

    for product in ('Client', 'Server', 'Files'):
        info = plistlib.loads((ROOT / f'Resources/{product}-Info.plist').read_bytes())
        assert info['CFBundleDevelopmentRegion'] == 'en'
        assert info['CFBundleLocalizations'] == list(LANGUAGES)
        expected = {key for key in info if key.endswith('UsageDescription')}
        for language in LANGUAGES:
            table = read_strings(ROOT / f'Resources/Localization/{product}/{language}.lproj/InfoPlist.strings')
            assert table.keys() == expected, (product, language, expected - table.keys())
            if language == 'en':
                assert all(info[key] == value for key, value in table.items())
    streaming = {language: read_strings(ROOT / f'Resources/Localization/Client/{language}.lproj/Streaming.strings') for language in LANGUAGES}
    manifest = json.loads((ROOT / 'scripts/streaming-localization.json').read_text())
    assert set(streaming['en']) == {key for keys in manifest.values() for key in keys}
    for language in LANGUAGES:
        assert streaming[language].keys() == streaming['en'].keys()
        for key, value in streaming[language].items():
            assert value.strip() and placeholders(key) == placeholders(value), (language, key)
    # Stable selection/persistence and protocol values must not become translated strings.
    protocol = (ROOT / 'Sources/Shared/Protocol.swift').read_text()
    assert 'public var resolution = "Match device"' in protocol
    server = (ROOT / 'Sources/Server/ServerModel.swift').read_text()
    assert 'status == "Ready" || status == "Connected"' in server
    assert 'status != "Stopped"' in server
    print(f'PASS: {len(english)} strings, {len(plurals["en"])} plural keys, 10 streaming overlays, five complete localizations and all permission keys')
    return tables, plurals


def runtime(tables, plurals):
    # A real app bundle ensures main-bundle negotiation also has the five supported languages.
    with tempfile.TemporaryDirectory(prefix='nocturne-localization-') as tmp:
        contents = pathlib.Path(tmp) / 'LocalizationTest.app/Contents'
        resources = contents / 'Resources'
        executable = contents / 'MacOS/LocalizationTest'
        executable.parent.mkdir(parents=True)
        bundle = resources / 'NocturneResources.bundle'
        shutil.copytree(RESOURCES, bundle)
        for language in LANGUAGES:
            shutil.copytree(ROOT / f'Resources/Localization/Client/{language}.lproj', resources / f'{language}.lproj')
        info = {'CFBundleIdentifier': 'test.nocturne.localization', 'CFBundleExecutable': executable.name,
                'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': list(LANGUAGES)}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
        source = pathlib.Path(tmp) / 'main.swift'
        source.write_text('''import Foundation
extension Bundle { static let module = Bundle.main.url(forResource: "NocturneResources", withExtension: "bundle").flatMap(Bundle.init(url:))! }
let values: [String: Any] = [
    "streaming": Bundle.main.localizedString(forKey: "N/A", value: nil, table: "Streaming"),
    "permission": Bundle.main.localizedInfoDictionary?["NSCameraUsageDescription"] as? String ?? "missing",
    "files": L("Files"), "unknown": L("user text %s 🤖"),
    "argument": L("Open %@", "literal %@ / O'Neil 🤖"),
    "error": NocturneLocalization.message("Install tool-%@ on your Mac or set its full path in Sharing → Chat providers."),
    "keychain": NocturneLocalization.message("Keychain operation failed (-50)."),
    "opaque": NocturneLocalization.message("opaque agent reply %s"),
    "plural": [0, 1, 2, 100].map { LCount("%d files", $0) },
    "actions": [0, 1, 2].map { LCount("Ran %d tool actions", $0) },
    "development": Bundle.module.developmentLocalization ?? "missing",
    "state": NocturneLocalization.pullRequestState("active"),
    "unknownState": NocturneLocalization.pullRequestState("custom_machine_state")
]
print(String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!)
''')
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(pathlib.Path(tmp) / 'ModuleCache'),
                        str(ROOT / 'Sources/Shared/Localization.swift'), str(source), '-o', str(executable)], check=True)
        cases = {'en': 'en', 'de-AT': 'de', 'fr-CA': 'fr', 'it-CH': 'it', 'es-MX': 'es', 'ja': 'en', 'ja, it-CH': 'it', 'fr-CA, de-AT': 'fr'}
        for preference, language in cases.items():
            result = subprocess.run([str(executable), '-AppleLanguages', f'({preference})'], check=True, capture_output=True)
            output = json.loads(result.stdout)
            assert output['streaming'] == read_strings(ROOT / f'Resources/Localization/Client/{language}.lproj/Streaming.strings')['N/A']
            assert output['permission'] == read_strings(ROOT / f'Resources/Localization/Client/{language}.lproj/InfoPlist.strings')['NSCameraUsageDescription']
            assert output['files'] == tables[language]['Files'], (preference, output)
            assert output['unknown'] == 'user text %s 🤖'
            assert output['opaque'] == 'opaque agent reply %s'
            assert output['keychain'] == tables[language]['Keychain operation failed (%@).'].replace('%@', '-50')
            assert output['unknownState'] == 'custom_machine_state'
            assert output['argument'] == tables[language]['Open %@'].replace('%@', "literal %@ / O'Neil 🤖")
            expected_error = tables[language]['Install %@ on your Mac or set its full path in Sharing → Chat providers.'].replace('%@', 'tool-%@')
            assert output['error'] == expected_error, (preference, output['error'])
            for index, number in enumerate((0, 1, 2, 100)):
                category = 'one' if number == 1 or (language == 'fr' and number == 0) else 'other'
                expected = plurals[language]['%d files']['count'][category].replace('%d', str(number))
                assert output['plural'][index] == expected, (preference, output['plural'])
            for index, number in enumerate((0, 1, 2)):
                category = 'one' if number == 1 or (language == 'fr' and number == 0) else 'other'
                assert output['actions'][index] == plurals[language]['Ran %d tool actions']['count'][category].replace('%d', str(number))
            assert output['development'] == 'en'
            assert output['state'] == tables[language]['Open']
            print(f'PASS: native Bundle negotiation {preference} → {language}, fallback, interpolation, remote error and plurals')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    data = check()
    if args.runtime:
        runtime(*data)
