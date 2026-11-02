"""Download only pinned, checksum-verified upstream tools for the target CPU.

    download.py <track> <amd64|arm64> <destination>

Every file is fetched over HTTPS, compared with the SHA-256 recorded here, and
only then unpacked. A new version means new URLs and new checksums for both
CPUs, taken from the upstream release's own checksum file where it publishes
one, and an upstream release at least 14 days old.
"""

import hashlib
import io
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

GITEA = "28.2.0"
GITEA_RUNNER = "5.1.1"
BUILDKIT = "0.34.0"
ROOTLESSKIT = "3.3.0"
ARGOCD = "3.5.5"
OPENTOFU = "1.13.1"
NODE = "26.12.0"
CODE_SERVER = "4.141.0"
# Playwright 1.64.1 ships this Chrome for Testing headless shell, as revision 1248.
PLAYWRIGHT_BROWSER_REVISION = "1248"
CHROME_HEADLESS_SHELL = "156.0.8078.4"

CHECKSUMS = {
    "gitea": {
        "amd64": "15681fc615d56611c274f52803fef4d6d5316b620f93b677dd4b831a74e50b9f",
        "arm64": "829d86679e412327c00234948fc812bff28a5800d6b3451beb18e6fd5c501ebe",
    },
    "gitea-runner": {
        "amd64": "0d589ce4e330a2f50c15c0d37475f8a6118885d831171d0986db93af8902ca6a",
        "arm64": "84d516dd566f09cd766ae2c07216d704fb0d00604ccc2997349bd14dfebc7d06",
    },
    "buildkit": {
        "amd64": "14813b1fb2a40082114e6d386c6fc5e7dd5298176ce7ee1a18bc33e73e109ac3",
        "arm64": "0619ca3e3205a32ea2beb115e0242136e4a0716cc1917ba0ceaa4ef4d52382c9",
    },
    "rootlesskit": {
        "amd64": "0e757c8f80510d764df8c9a5f169805580b48d02329f0a200900e261ecec27ed",
        "arm64": "7a159e79ef3e65e1f2702ab89537bb79de67b433428328b9626cf75786dbe43a",
    },
    "argocd": {
        "amd64": "c3ddfa606fc3e89ab14f55bda6600b207c355b028f8eaabe69b817a4c4621aba",
        "arm64": "13f423b9014e212a3e0052b7826e1d6b95ee5ac156f2436fc856f2eb8c827537",
    },
    "tofu": {
        "amd64": "8ccbc6f8ee21d2827715f3c6e08a9b3e0209b1e62057c05067ef117e047c1a80",
        "arm64": "b9614df40575cc3fc10a8a25025b7245d961da279f715ea3efff4ddae8e6938a",
    },
    "node": {
        "amd64": "fd47865ecd6391ebb431fc815e01b9135bf83ded5cf373247e9331e196b7aded",
        "arm64": "fd6cc729fa4448c2ac27c3fca5606019ced63c65a15c152c8df03e0cbce7f4c5",
    },
    "code-server": {
        "amd64": "65bcd20b524d03eb1b5adb7f360244599ef0e5b74089a46a982d32c074b97a29",
        "arm64": "e5cc78da1d631c6cf6162f9b18eeaa8ee9d3239e1a88bb99d0602cdc5fa1852d",
    },
    "chrome-headless-shell": {
        "amd64": "c3e50596aef52c58f8fda3c6b3411c33d34c88b177b3ed1c2243359fd3b8ba20",
        "arm64": "81ab9d4d3c301dc5fdfb6c541b9e6632b16fc819a6a854460f40a76fe2b2c476",
    },
}

TRACKS = {
    "cicd": ("gitea", "gitea-runner", "buildkit", "rootlesskit", "argocd"),
    "iac": ("tofu",),
    "web": ("node", "code-server", "chrome-headless-shell"),
}


def specs(arch):
    """Name -> (URL, how to unpack). Upstream spells the CPUs differently."""
    kernel_arch = {"amd64": "x86_64", "arm64": "aarch64"}[arch]
    node_arch = {"amd64": "x64", "arm64": "arm64"}[arch]
    chrome = {"amd64": "linux64", "arm64": "linux-arm64"}[arch]
    return {
        "gitea": (f"https://dl.gitea.com/gitea/{GITEA}/gitea-{GITEA}-linux-{arch}", "binary"),
        "gitea-runner": (
            f"https://dl.gitea.com/gitea-runner/{GITEA_RUNNER}/gitea-runner-{GITEA_RUNNER}-linux-{arch}",
            "binary",
        ),
        "buildkit": (
            f"https://github.com/moby/buildkit/releases/download/v{BUILDKIT}/buildkit-v{BUILDKIT}.linux-{arch}.tar.gz",
            "tar",
        ),
        "rootlesskit": (
            f"https://github.com/rootless-containers/rootlesskit/releases/download/v{ROOTLESSKIT}/rootlesskit-{kernel_arch}.tar.gz",
            "tar",
        ),
        "argocd": (
            f"https://github.com/argoproj/argo-cd/releases/download/v{ARGOCD}/argocd-linux-{arch}",
            "binary",
        ),
        "tofu": (
            f"https://github.com/opentofu/opentofu/releases/download/v{OPENTOFU}/tofu_{OPENTOFU}_linux_{arch}.zip",
            "zip",
        ),
        "node": (f"https://nodejs.org/dist/v{NODE}/node-v{NODE}-linux-{node_arch}.tar.xz", "tree"),
        "code-server": (
            f"https://github.com/coder/code-server/releases/download/v{CODE_SERVER}/code-server-{CODE_SERVER}-linux-{arch}.tar.gz",
            "tree",
        ),
        "chrome-headless-shell": (
            f"https://cdn.playwright.dev/builds/cft/{CHROME_HEADLESS_SHELL}/{chrome}/chrome-headless-shell-{chrome}.zip",
            "browser",
        ),
    }


# Only these files leave an archive: everything else in it (BuildKit's QEMU and
# CNI helpers, documentation, a second copy of a binary) stays out of the image.
BUILDKIT_FILES = ("buildctl", "buildkitd", "buildkit-runc")
ROOTLESSKIT_FILES = ("rootlesskit", "rootlessctl")


def fetch(url):
    """The whole response body. dl.gitea.com refuses Python's default user agent."""
    request = urllib.request.Request(url, headers={"User-Agent": "mylabskills-lab-images-download/1"})
    for attempt in range(1, 5):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError) as error:
            retryable = not isinstance(error, urllib.error.HTTPError) or error.code >= 500
            if attempt == 4 or not retryable:
                raise
            time.sleep(5 * attempt)


def write_executable(destination, name, data):
    target = destination / name
    target.write_bytes(data)
    target.chmod(0o755)


def unpack_tar(destination, name, data):
    wanted = {"buildkit": BUILDKIT_FILES, "rootlesskit": ROOTLESSKIT_FILES}[name]
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if member.isfile() and Path(member.name).name in wanted:
                write_executable(destination, Path(member.name).name, archive.extractfile(member).read())
    missing = [tool for tool in wanted if not (destination / tool).exists()]
    if missing:
        raise SystemExit(f"{name}: {', '.join(missing)} missing from the archive")


def unpack_tree(destination, name, data):
    """A tarball with one versioned parent directory, kept whole."""
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            member.name = "/".join(Path(member.name).parts[1:])
            if member.name:
                archive.extract(member, destination, filter="data")


def unpack_browser(destination, data):
    """Playwright's layout: <browsers path>/chromium_headless_shell-<revision>/<zip contents>."""
    root = destination / f"chromium_headless_shell-{PLAYWRIGHT_BROWSER_REVISION}"
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for item in archive.infolist():
            target = root / item.filename
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not target.resolve().is_relative_to(root.resolve()):
                raise SystemExit(f"unsafe path in the browser archive: {item.filename}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(item))
            target.chmod((item.external_attr >> 16) & 0o777 or 0o644)
    # Playwright treats a browser directory without this marker as not installed.
    (root / "INSTALLATION_COMPLETE").touch()


def main():
    track, arch, destination = sys.argv[1:]
    if arch not in ("amd64", "arm64") or track not in TRACKS:
        raise SystemExit("unsupported track/architecture")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    available = specs(arch)
    for name in TRACKS[track]:
        url, kind = available[name]
        data = fetch(url)
        if hashlib.sha256(data).hexdigest() != CHECKSUMS[name][arch]:
            raise SystemExit(f"{name}: checksum mismatch")
        if kind == "binary":
            write_executable(destination, name, data)
        elif kind == "tar":
            unpack_tar(destination, name, data)
        elif kind == "zip":
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                write_executable(destination, name, archive.read(name))
        elif kind == "tree":
            unpack_tree(destination / name, name, data)
        elif kind == "browser":
            unpack_browser(destination, data)


if __name__ == "__main__":
    main()
