"""Record runtime-created assets in the installer's reversible file journal."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import shutil


@contextmanager
def managed_paths(paths):
    home = Path.home()
    state = Path(os.environ.get('XDG_STATE_HOME', home / '.local/state')) / 'lucid'
    manifest = state / 'manifest'
    if not manifest.is_file():  # manual installations have no restoration contract
        yield
        return
    with (state / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (state / 'uninstall-started').exists():
            raise RuntimeError('Lucid uninstall is in progress')
        records = [line.split('\t') for line in manifest.read_text().splitlines()]
        known = {r[1] for r in records if len(r) > 1 and r[0] in ('created', 'saved', 'moved')}
        parents = {r[1] for r in records if len(r) > 1 and r[0] == 'mkdir'}
        with manifest.open('a') as journal:
            def record(*fields):
                journal.write('\t'.join(map(str, fields)) + '\n')
                journal.flush()
                os.fsync(journal.fileno())

            for item in paths:
                path = Path(os.path.abspath(item))
                if home not in path.parents or any(c in str(path) for c in '\t\n'):
                    raise ValueError(f'Unmanaged asset path: {path}')
                for part in (path, *path.parents):
                    if part == home:
                        break
                    if part.is_symlink():
                        raise ValueError(f'Symlinked asset path: {part}')
                if any(str(part) in known for part in (path, *path.parents)):
                    continue
                if path.exists():
                    backup = state / 'originals' / str(path).lstrip('/')
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    if path.is_dir():
                        shutil.copytree(path, backup, symlinks=True, dirs_exist_ok=True)
                    else:
                        shutil.copy2(path, backup)
                    record('saved', path, backup)
                else:
                    missing = []
                    for part in path.parents:
                        if part.exists():
                            break
                        missing.append(part)
                    for part in reversed(missing):
                        if str(part) not in parents:
                            record('mkdir', part)
                            parents.add(str(part))
                    record('created', path)
                known.add(str(path))
        yield
