#!/usr/bin/env python3
"""Stage a single Homebrew media dependency closure into a local test app.

Modifies only the supplied .app. Sign it after running this script. This does not
validate deployment targets, notarization, licenses or clean-machine portability.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
app = Path(sys.argv[1]).resolve()
frameworks = app / 'Contents/Frameworks'
if app.suffix != '.app' or not frameworks.is_dir():
    raise SystemExit('Expected an already built .app with Contents/Frameworks')
source = root / 'build/dv/mpv-build/libmpv.2.dylib'
brew = Path(os.environ.get('BREW_PREFIX', '/opt/homebrew')).resolve()
seen = {}
manifest = []


def dependencies(path):
    lines = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()
    return [line.strip().split(' (compatibility')[0] for line in lines[2:]]


def stage(path):
    name = path.name
    original = path.resolve()
    if name in seen:
        if seen[name] != original:
            raise RuntimeError(f'Conflicting dylibs named {name}: {seen[name]} and {original}')
        return
    seen[name] = original
    target = frameworks / name
    # Do not follow a pre-existing bundled symlink when replacing its contents.
    if target.is_symlink():
        target.unlink()
    shutil.copy2(original, target)
    target.chmod(0o755)
    changes = []
    for dependency in dependencies(original):
        dep = Path(dependency)
        if dep.is_absolute() and dep.is_relative_to(brew):
            stage(dep)
            changes += ['-change', dependency, '@rpath/' + dep.name]
        elif dependency.startswith(('@rpath/', '@loader_path/')):
            # Homebrew libraries commonly use a sibling-relative rpath.
            sibling = original.parent / dependency.split('/', 1)[1]
            if not sibling.is_file() or not sibling.resolve().is_relative_to(brew):
                raise RuntimeError(f'Unresolved input dependency: {original}: {dependency}')
            stage(sibling)
            changes += ['-change', dependency, '@rpath/' + sibling.name]
        elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError(f'Unexpected dependency: {dependency}')
    subprocess.run(['install_name_tool', '-id', '@rpath/' + name, *changes, str(target)], check=True)
    manifest.append({'library': name, 'source': str(original)})


stage(source)
# The executable and older bundled libraries reference some equivalent Homebrew
# aliases by their major SONAME. Existing references keep working after replacement.
for item in manifest:
    path = frameworks / item['library']
    for dependency in dependencies(path):
        if dependency.startswith('@rpath/') and not (frameworks / dependency[7:]).exists():
            raise RuntimeError(f'Missing bundled dependency: {dependency}')
        if dependency.startswith(str(brew)):
            raise RuntimeError(f'Unrelocated dependency: {dependency}')
(app / 'Contents/media-dependencies.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Staged {len(manifest)} media libraries into {app}')
