#!/usr/bin/env python3
"""Self-check for bin/omarchy-cameras-thumbd. Run: python3 test_thumbd.py

Covers the runtime directory rule, which is the part that fails dangerously
rather than visibly: writing camera frames and IPC sockets into a path someone
else controls would hand them the streams. Every rejection here has to stay a
rejection, so the assertions are about what is refused, not what works.
"""

import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile

spec = importlib.util.spec_from_loader(
    "thumbd",
    importlib.machinery.SourceFileLoader(
        "thumbd", str(pathlib.Path(__file__).parent / "bin" / "omarchy-cameras-thumbd")))
thumbd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(thumbd)


def refuses(base, note):
    os.environ["XDG_RUNTIME_DIR"] = str(base)
    try:
        thumbd.runtime_dir()
    except RuntimeError:
        return
    raise AssertionError(note)


with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)

    # No XDG_RUNTIME_DIR at all: refuse rather than fall back to a shared /tmp,
    # where the path would be predictable and anyone could get there first.
    os.environ.pop("XDG_RUNTIME_DIR", None)
    try:
        thumbd.runtime_dir()
        raise AssertionError("an unset XDG_RUNTIME_DIR must not be worked around")
    except RuntimeError:
        pass

    # The ordinary case: created fresh, and shut to everyone else.
    fresh = tmp / "fresh"
    fresh.mkdir()
    os.environ["XDG_RUNTIME_DIR"] = str(fresh)
    made = thumbd.runtime_dir()
    assert made == fresh / "omarchy-cameras", made
    assert made.stat().st_mode & 0o777 == 0o700, oct(made.stat().st_mode)

    # Second call finds its own directory and accepts it.
    assert thumbd.runtime_dir() == made

    # A symlink is refused, not followed. Following one lets anybody who can
    # write the parent redirect every frame into a directory they read.
    linked = tmp / "linked"
    linked.mkdir()
    (linked / "elsewhere").mkdir()
    (linked / "omarchy-cameras").symlink_to(linked / "elsewhere")
    refuses(linked, "a symlink must not be followed")

    # A plain file where the directory belongs.
    filed = tmp / "filed"
    filed.mkdir()
    (filed / "omarchy-cameras").write_text("")
    refuses(filed, "a file must not pass as a directory")

    # Readable by others: a camera frame is a picture of someone's home.
    loose = tmp / "loose"
    loose.mkdir()
    (loose / "omarchy-cameras").mkdir(mode=0o755)
    refuses(loose, "a world-readable directory must not be reused")

print("ok")
