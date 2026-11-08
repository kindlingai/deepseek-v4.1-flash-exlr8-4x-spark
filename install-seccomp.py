#!/usr/bin/env python3
"""Install a locally generated Docker-default-plus-io_uring profile for this recipe."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
PROFILE = "seccomp-iouring.json"
CALLS = ["io_uring_setup", "io_uring_enter", "io_uring_register"]


def write_atomic(path, text):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix="." + path.name + ".", delete=False) as f:
        tmp = Path(f.name)
        try:
            f.write(text)
            f.close()
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)


def select_profile(value):
    # Keep the user's other settings, and replace only our Compose selector.
    path = ROOT / ".env"
    text = path.read_text() if path.exists() else ""
    lines = [line for line in text.splitlines(keepends=True)
             if not re.match(r"^\s*(?:export\s+)?SECCOMP_PROFILE\s*=", line)]
    text = "".join(lines)
    if text and not text.endswith("\n"):
        text += "\n"
    write_atomic(path, text + "SECCOMP_PROFILE=" + value + "\n")


def install():
    # Disable any previously generated profile before fetching a version-specific replacement.
    # A failed fetch must never leave Compose using a stale profile from another Docker version.
    select_profile("builtin")
    try:
        version = subprocess.run(["docker", "version", "--format", "{{.Server.Version}}"],
                                 check=True, capture_output=True, text=True, timeout=20).stdout.strip()
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.+-]+)?", version):
            raise ValueError("Docker server did not report a release version")
        tag = "docker-v" + version
        url = ("https://raw.githubusercontent.com/moby/moby/" + tag +
               "/vendor/github.com/moby/profiles/seccomp/default.json")
        fetched = subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                                  "--proto", "=https", "--proto-redir", "=https", "--max-time", "30", url],
                                 check=True, capture_output=True, text=True, timeout=35)
        profile = json.loads(fetched.stdout)
        if not isinstance(profile, dict) or profile.get("defaultAction") != "SCMP_ACT_ERRNO" or not isinstance(profile.get("syscalls"), list):
            raise ValueError("download is not a Docker default seccomp profile")
        profile["syscalls"].append({"names": CALLS, "action": "SCMP_ACT_ALLOW",
                                    "comment": "Local Docker default plus Engram io_uring"})
        write_atomic(ROOT / PROFILE, json.dumps(profile, indent=1) + "\n")
        select_profile("./" + PROFILE)
        print(f"Installed {PROFILE} from Moby {tag}; Compose allows the three io_uring syscalls.")
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f"WARNING: could not install io_uring seccomp profile ({e}); Compose will use Docker's builtin "
              "profile. Engram can fall back to pread when io_uring is denied.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 1:
        print("Usage: ./install-seccomp.py  (run before docker compose up, and after Docker upgrades)", file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(install())
    except OSError as e:
        print(f"ERROR: cannot update the local Compose settings: {e}", file=sys.stderr)
        sys.exit(1)
