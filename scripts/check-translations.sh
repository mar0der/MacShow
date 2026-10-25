#!/bin/bash
# Lists on-screen text that has no Bulgarian translation yet. The compiler
# reports every localizable string literal; strings built at runtime with
# LocalizedStringKey("…") are collected from the source too.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swift build --product MacShow -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" > /dev/null 2>&1
python3 - "$OUT" <<'PY'
import glob, json, re, subprocess, sys
keys = set()
for f in glob.glob(sys.argv[1] + '/*.stringsdata'):
    for table in json.load(open(f)).get('tables', {}).values():
        keys.update(e['key'] for e in table)
for f in glob.glob('Sources/MacShow/**/*.swift', recursive=True):
    keys.update(re.findall(r'LocalizedStringKey\("([^"\\]*)"\)', open(f).read()))
keys.discard('')
done = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'Resources/Localization/bg.lproj/Localizable.strings']))
missing = sorted(keys - done.keys())
print(f"{len(keys)} strings, {len(missing)} without Bulgarian")
for key in missing: print("  " + key)
PY
rm -rf "$OUT"
