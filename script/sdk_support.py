"""Build-time SDK integrity and recoverable directory replacement."""
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import tarfile
import urllib.request


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def digest(path, algorithm='sha256'):
    with path.open('rb') as source:
        return hashlib.file_digest(source, algorithm).hexdigest()


def download(url, archive, expected, algorithm='sha256'):
    if archive.exists() and digest(archive, algorithm) == expected:
        return
    partial = archive.with_name(archive.name + '.partial')
    try:
        with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as target:
            shutil.copyfileobj(response, target, 1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
        if digest(partial, algorithm) != expected:
            raise ValueError('SDK archive checksum mismatch; existing SDK was preserved')
        partial.replace(archive)
        sync_directory(archive.parent)
    finally:
        partial.unlink(missing_ok=True)


def extract_tar(archive, destination):
    with tarfile.open(archive) as tar:
        for entry in tar.getmembers():
            target = destination / entry.name
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError('Unsafe SDK archive path')
            if not (entry.isfile() or entry.isdir() or entry.issym() or entry.islnk()):
                raise ValueError('Unsupported SDK archive member')
            if entry.issym() or entry.islnk():
                linked = (target.parent if entry.issym() else destination) / entry.linkname
                if not linked.resolve().is_relative_to(destination.resolve()):
                    raise ValueError('Unsafe SDK archive link')
        # Python's data filter also rejects links whose resolved targets escape staging.
        tar.extractall(destination, filter='data')


def manifest(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        name = path.relative_to(directory).as_posix()
        if name == '.lite-sdk.json':
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(directory.resolve()):
                raise ValueError('SDK link escapes installation')
            result[name] = {'link': os.readlink(path)}
        elif path.is_file():
            result[name] = {'sha256': digest(path), 'executable': bool(path.stat().st_mode & 0o111)}
    return result


def write_receipt(directory, identity):
    with (directory / '.lite-sdk.json').open('w') as receipt:
        json.dump({'identity': identity, 'files': manifest(directory)}, receipt, sort_keys=True)
        receipt.flush()
        os.fsync(receipt.fileno())
    sync_directory(directory)


def valid_receipt(directory, identity):
    try:
        receipt = json.loads((directory / '.lite-sdk.json').read_text())
        return receipt['identity'] == identity and receipt['files'] == manifest(directory)
    except (OSError, ValueError, KeyError, TypeError):
        return False


@contextlib.contextmanager
def installation_lock(vendor, name):
    vendor.mkdir(parents=True, exist_ok=True)
    with (vendor / ('.' + name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def recover(destination):
    previous = destination.with_name('.' + destination.name + '.previous')
    if previous.exists() and not destination.exists():
        previous.rename(destination)
        sync_directory(destination.parent)
    return previous


def replace_directory(staged, destination, validate):
    if not validate(staged):
        raise ValueError("Staged installation failed verification; existing installation preserved")
    previous = recover(destination)
    if previous.exists():
        # A completed replacement was interrupted before cleanup. Never remove its
        # recovery tree unless the installed replacement has passed validation.
        if not validate(destination):
            raise ValueError('Incomplete SDK replacement: recovery tree preserved at ' + str(previous))
        shutil.rmtree(previous)
    if destination.exists():
        destination.rename(previous)
        sync_directory(destination.parent)
    try:
        staged.rename(destination)
        sync_directory(destination.parent)
        if not validate(destination):
            raise ValueError('Installed SDK failed verification')
    except BaseException:
        if destination.exists():
            shutil.rmtree(destination)
        if previous.exists():
            previous.rename(destination)
            sync_directory(destination.parent)
        raise
    if previous.exists():
        shutil.rmtree(previous)
