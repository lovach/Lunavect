#!/usr/bin/env python3
"""Record source before a build and artifact hashes after it; not a reproducible-byte guarantee."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import tempfile


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True).encode()).hexdigest()


def git(root, *args):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    if result.returncode:
        raise ValueError('Git could not inspect the source checkout')
    return result.stdout


def source_root(path):
    root = path.resolve()
    actual = Path(os.fsdecode(git(root, 'rev-parse', '--show-toplevel')).strip()).resolve()
    if root != actual:
        raise ValueError('--source-root must name the Git checkout root')
    return root


def check_manifest_path(root, path):
    """A manifest must not become part of the source snapshot it describes."""
    try:
        relative = path.resolve().relative_to(root)
    except ValueError:
        return
    if git(root, 'ls-files', '-z', '--', str(relative)):
        raise ValueError('Manifest output must not overwrite a tracked source file')
    ignored = subprocess.run(['git', '-C', str(root), 'check-ignore', '--quiet',
                              '--no-index', '--', str(relative)]).returncode
    if ignored != 0:
        raise ValueError('Manifest output must be outside the checkout or in a Git-ignored location')


def entry(path, name):
    details = path.lstat()
    item = {'path': name, 'mode': stat.S_IMODE(details.st_mode)}
    if stat.S_ISLNK(details.st_mode):
        # Hash the link itself; never follow a product link into a private directory.
        item.update(type='symlink', sha256=hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest())
    elif stat.S_ISREG(details.st_mode):
        item.update(type='file', size=details.st_size, sha256=sha256_file(path))
    elif stat.S_ISDIR(details.st_mode):
        item.update(type='directory')
    else:
        raise ValueError('Unsupported special file in source or requested artifact')
    return item


def snapshot(root):
    """Hash content and index, without publishing filenames, diffs or ignored files."""
    paths = git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0')
    entries = []
    for raw in sorted(set(paths) - {b''}):
        name = os.fsdecode(raw)
        try:
            item = entry(root / name, name)
        except FileNotFoundError:
            item = {'path': name, 'type': 'missing'}
        if item['type'] == 'directory':
            raise ValueError('Submodules are not supported by this source fingerprint')
        entries.append(item)
    status = git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all')
    return {
        'commit': git(root, 'rev-parse', 'HEAD').decode().strip(),
        'dirty': bool(status),
        'fingerprint_sha256': json_digest(entries),
        'index_sha256': hashlib.sha256(git(root, 'ls-files', '--stage', '-z')).hexdigest(),
        'status_sha256': hashlib.sha256(status).hexdigest(),
        'file_count': len(entries),
        'scope': 'tracked-and-nonignored-untracked-files; ignored files excluded',
    }


def tool_version(command, patterns):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return {'status': 'unavailable'}
    if result.returncode:
        return {'status': 'unavailable'}
    # Never persist raw command output: tool diagnostics can contain personal paths.
    values = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, result.stdout + '\n' + result.stderr, re.MULTILINE)
        if match:
            values[key] = match.group(1)
    return {'status': 'recorded', **values} if values else {'status': 'unavailable'}


def toolchain():
    return {
        'xcode': tool_version(['xcodebuild', '-version'], {
            'version': r'^Xcode ([0-9]+(?:\.[0-9]+)*)\s*$',
            'build': r'^Build version ([A-Za-z0-9.]+)\s*$',
        }),
        'swift': tool_version(['swift', '--version'], {
            'version': r'^(?:Apple )?Swift version ([0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.]+)?)\b',
            'compiler_build': r'\b(swiftlang-[A-Za-z0-9.]+)\b',
        }),
        'python': platform.python_version(),
        'macos': platform.mac_ver()[0] or None,
        'architecture': platform.machine(),
    }


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def write_manifest(path, value, create=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     prefix='.manifest-', delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=True)
        stream.write('\n')
    try:
        if create:
            # Exclusive creation also prevents two concurrent begin calls colliding.
            os.link(temporary, path)
        else:
            temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def artifact(name, path):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
        raise ValueError('Artifact labels must use letters, numbers, dots, underscores or hyphens')
    try:
        root = entry(path, '.')
    except FileNotFoundError:
        raise ValueError(f'Requested artifact is missing: {name}') from None
    if root['type'] != 'directory':
        return {'name': name, **{key: value for key, value in root.items() if key != 'path'}}
    entries = [root]
    for directory, folders, files in os.walk(path, followlinks=False):
        for child in sorted(folders + files):
            child_path = Path(directory) / child
            entries.append(entry(child_path, child_path.relative_to(path).as_posix()))
    entries.sort(key=lambda item: item['path'])
    return {'name': name, 'type': 'directory', 'sha256': json_digest(entries),
            'hash_method': 'sha256-canonical-json-entries-v1', 'entries': entries}


def begin(args, root):
    # A distribution manifest must never silently certify a dirty candidate.
    args.require_clean = args.require_clean or args.kind == 'distribution'
    if args.output.exists():
        raise ValueError('Manifest already exists; use a new output for each build')
    check_manifest_path(root, args.output)
    source_before = snapshot(root)
    if args.require_clean and source_before['dirty']:
        raise ValueError('--require-clean requires a clean Git checkout before the build')
    value = {
        'schema_version': 1,
        'kind': args.kind,
        'status': 'started',
        'started_at_utc': utc_now(),
        'source_before': source_before,
        'clean_source_required': args.require_clean,
        'toolchain': toolchain(),
        'limitations': [
            'Source is observed at begin/finalize checkpoints, not copied or locked; '
            'changes reverted between checkpoints cannot be detected.',
            'Ignored source files, signing settings, environment and dependency caches are not captured.',
            'Hashes identify observed artifacts; this is not a signing, notarization or reproducible-byte guarantee.',
        ],
    }
    write_manifest(args.output, value, create=True)


def finalize(args, root):
    check_manifest_path(root, args.manifest)
    value = json.loads(args.manifest.read_text())
    if value.get('schema_version') != 1 or value.get('status') != 'started' or 'source_before' not in value:
        raise ValueError('Expected an unfinished version 1 manifest from begin')
    requested = []
    if args.app:
        requested.append(('app', args.app))
    for specification in args.artifact:
        name, separator, path = specification.partition('=')
        if not separator or not path:
            raise ValueError('--artifact requires LABEL=PATH')
        requested.append((name, Path(path)))
    if not requested:
        raise ValueError('Finalize requires --app or at least one --artifact')
    if len({name for name, _ in requested}) != len(requested):
        raise ValueError('Artifact labels must be unique')
    for _, path in requested:
        # Rewriting this file after hashing it would invalidate its own artifact hash.
        if path.resolve() == args.manifest.resolve() or (
                path.is_dir() and args.manifest.resolve().is_relative_to(path.resolve())):
            raise ValueError('A requested artifact must not contain its own manifest')
    value['artifacts'] = [artifact(name, path) for name, path in requested]
    value['product_version'] = {'status': 'not-run', 'reason': 'No app bundle requested'}
    if args.app:
        info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
        if not isinstance(version, str) or not re.fullmatch(r'\d+(?:\.\d+){0,3}', version):
            raise ValueError('App Info.plist must contain a numeric version')
        if not isinstance(build, str) or not re.fullmatch(r'\d+', build):
            raise ValueError('App Info.plist must contain a numeric build')
        value['product_version'] = {'status': 'recorded', 'version': version, 'build': build}
    value['source_after'] = snapshot(root)
    changed = value['source_before'] != value['source_after']
    value['source_integrity'] = 'changed' if changed else 'observed-unchanged'
    value['status'] = 'source-changed' if changed else 'complete'
    value['finished_at_utc'] = utc_now()
    write_manifest(args.manifest, value)
    if changed:
        raise ValueError('Source changed after begin; manifest records both checkpoints and cannot identify a fixed build source')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('begin', help='Record source before starting the build')
    start.add_argument('--source-root', required=True, type=Path)
    start.add_argument('--output', required=True, type=Path)
    start.add_argument('--kind', choices=('unsigned-check', 'native-render', 'synthetic-performance', 'distribution', 'unspecified'),
                       default='unspecified')
    start.add_argument('--require-clean', action='store_true',
                       help='Reject dirty source before writing a manifest (always required for distribution)')
    finish = commands.add_parser('finalize', help='Hash products and compare the source checkpoint')
    finish.add_argument('--source-root', required=True, type=Path)
    finish.add_argument('--manifest', required=True, type=Path)
    finish.add_argument('--app', type=Path)
    finish.add_argument('--artifact', action='append', default=[], metavar='LABEL=PATH')
    args = parser.parse_args()
    try:
        root = source_root(args.source_root)
        (begin if args.command == 'begin' else finalize)(args, root)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        # Do not copy OS exception filenames (possibly personal paths) into diagnostics.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, f'Build manifest failed: {message}\n')
    print(f'Build manifest {args.command}: passed')


if __name__ == '__main__':
    main()
