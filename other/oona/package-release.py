#!/usr/bin/env python3
"""Package an already built, bundled app as an isolated Apple Silicon release.

Usage: package-release.py BUNDLED_APP OUTPUT_DIRECTORY VERSION
Run bundle-libmpv.py first. OUTPUT_DIRECTORY must not exist. Does not publish.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
from urllib.parse import urlparse

root = Path(__file__).resolve().parents[2]
source, output, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
output.mkdir(parents=True, exist_ok=False)
app = output / 'Oona DV.app'
subprocess.run(['ditto', str(source), str(app)], check=True)
frameworks = app / 'Contents/Frameworks'
manifest = json.loads((app / 'Contents/media-dependencies.json').read_text())

# Remove leftover libraries from the stock IINA dependency bundle, keeping the
# transitive dylib closure actually linked by the executable and custom libmpv.
def dependencies(path):
    lines = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    return [line.strip().split(' (compatibility')[0] for line in lines]

needed = set()
pending = [app / 'Contents/MacOS/IINA']
while pending:
    for dep in dependencies(pending.pop()):
        if dep.startswith(('/opt/homebrew/', '/Users/')):
            raise RuntimeError(f'Unrelocated dependency: {dep}')
        if not dep.endswith('.dylib') or dep.startswith(('/usr/lib/', '/System/')):
            continue
        name = Path(dep).name
        if name in needed:
            continue
        path = frameworks / name
        if not path.exists():
            raise RuntimeError(f'Missing bundled library: {name}')
        needed.add(name)
        pending.append(path)
for path in frameworks.glob('*.dylib'):
    if path.name not in needed:
        path.unlink()

unmapped = needed - {item['library'] for item in manifest}
if unmapped:
    raise RuntimeError(f'Libraries without source provenance: {sorted(unmapped)}; '
                       'rebuild with -Wl,-dead_strip_dylibs')

notices = app / 'Contents/Resources/ThirdPartyNotices'
notices.mkdir(exist_ok=True)
shutil.copy2(root / 'LICENSE', notices / 'IINA-GPLv3.txt')
recipes = output / 'dependency-sources'
recipes.mkdir()
packages = {}
for item in manifest:
    if item['library'] not in needed:
        continue
    path = Path(item['source'])
    if not str(path).startswith('/opt/homebrew/Cellar/'):
        continue
    package = path.parts[4]
    prefix = Path(*path.parts[:6])
    if package in packages:
        continue
    formula = next((prefix / '.brew').glob('*.rb'))
    recipe = formula.read_text()
    target = recipes / package
    target.mkdir()
    shutil.copy2(formula, target / formula.name)
    url = re.search(r'^\s*url "([^"]+)"', recipe, re.M).group(1)
    packages[package] = {'version': prefix.name, 'source_url': url,
                         'build_recipe': f'{package}/{formula.name}'}
    dest = notices / package
    dest.mkdir()
    for entry in prefix.rglob('*'):
        if entry.is_file() and re.match(r'^(copying|copyright|licen[cs]e|notice|authors)([.\-_]|$)', entry.name, re.I):
            rel = entry.relative_to(prefix)
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(entry, dest / rel)
    if not any(dest.rglob('*')):
        # Some bottles omit license files; recover them from the exact, verified source.
        cache = root / 'build/dv/release-sources'
        cache.mkdir(exist_ok=True)
        archive = cache / Path(urlparse(url).path).name
        expected = re.search(r'^\s*sha256 "([0-9a-f]{64})"', recipe, re.M).group(1)
        if not archive.exists():
            subprocess.run(['curl', '-fL', '--retry', '2', url, '-o', str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Source checksum mismatch: {package}')
        with tarfile.open(archive) as tar:
            for entry in tar.getmembers():
                if entry.isfile() and ('/LICENSES/' in entry.name or
                    re.match(r'^(copying|copyright|licen[cs]e|notice)', Path(entry.name).name, re.I)):
                    (dest / Path(entry.name).name).write_bytes(tar.extractfile(entry).read())
        if not any(dest.iterdir()):
            raise RuntimeError(f'Missing license notices for {package}')
        shutil.copy2(archive, target / archive.name)

# Pin Swift package sources alongside their original copyright/license notices.
pins = json.loads((root / 'iina.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
checkouts = root / 'build/dv/xcode/SourcePackages/checkouts'
for pin in pins:
    name = pin['identity']
    checkout = next(p for p in checkouts.iterdir() if p.name.lower() == name)
    dest = notices / name
    dest.mkdir(exist_ok=True)
    for entry in checkout.iterdir():
        if entry.is_file() and re.match(r'^(copying|copyright|licen[cs]e|notice)', entry.name, re.I):
            shutil.copy2(entry, dest / entry.name)
    packages[name] = {'version': pin['state'].get('version'), 'source_url': pin['location'],
                      'revision': pin['state']['revision']}

mpv = next((root / 'build/dv').glob('mpv-*/LICENSE.GPL'))
shutil.copy2(mpv, notices / 'mpv-GPL.txt')
shutil.copy2(root / 'build/dv/mpv-source.tar.gz', recipes / 'mpv-source.tar.gz')
shutil.copytree(root / 'other/oona/patches', recipes / 'mpv-patches')
packages['mpv'] = {'revision': '97179bce7ed980c53647d6344916f632fe689e9e',
                   'source_url': 'https://github.com/lhc70000/mpv',
                   'archive': 'mpv-source.tar.gz', 'patches': 'mpv-patches'}
(recipes / 'sources.json').write_text(json.dumps(packages, indent=2) + '\n')
shutil.copy2(recipes / 'sources.json', notices / 'sources.json')
# Strip developer-local paths from the public manifest.
(app / 'Contents/media-dependencies.json').write_text(json.dumps(
    [{'library': name} for name in sorted(needed)], indent=2) + '\n')

info = app / 'Contents/Info.plist'
plist = plistlib.loads(info.read_bytes())
plist.update(CFBundleIdentifier='io.github.evansyu.oona-dv', CFBundleName='Oona DV',
             CFBundleDisplayName='Oona DV', CFBundleShortVersionString=version,
             CFBundleVersion='1', LSMinimumSystemVersion='27.0.1',
             SUEnableAutomaticChecks=False, NSSupportsPersistentWindowState=False)
plist.pop('SUFeedURL', None)
info.write_bytes(plistlib.dumps(plist))
for binary in [app / 'Contents/MacOS/IINA', *frameworks.glob('*.dylib')]:
    arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True)
    if 'arm64' not in arch.split():
        raise RuntimeError(f'Not Apple Silicon compatible: {binary.name}')
subprocess.run(['codesign', '--force', '--deep', '-s', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'Packaged {app}; retained {len(needed)} linked media libraries')
