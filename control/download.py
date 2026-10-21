"""Download only pinned, checksum-verified upstream tools for the target CPU."""

import hashlib
import io
from pathlib import Path
import sys
import tarfile
import urllib.request

CHECKSUMS = {
    "kubectl": {
        "amd64": "874d5e72dbb819f43cff16bcd1e4f8bac5b7f2361fe1e55049b0a6c676fb0cbf",
        "arm64": "cc749967b62f4422260bc9c0aa7a7c55f45175ae38cb8d95767b5d2b7e04c1fd",
    },
    "helm": {
        "amd64": "1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb",
        "arm64": "f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310",
    },
    "k9s": {
        "amd64": "c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7",
        "arm64": "3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c",
    },
    "code-server": {
        "amd64": "9303165b7fd43532091922f77e2f119ff2fa109c6b6f1c3c966fb02f3d6d9c8b",
        "arm64": "0fba760298fe06480d940e218f0873a645ba1e7e3ac4b527059af82d85a90462",
    },
}


def main():
    tier, arch, destination = sys.argv[1:]
    if arch not in ("amd64", "arm64") or tier not in ("k8s", "dev"):
        raise SystemExit("unsupported tier/architecture")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    specs = {
        "kubectl": (
            f"https://dl.k8s.io/release/v1.35.8/bin/linux/{arch}/kubectl",
            None,
        ),
        "helm": (
            f"https://get.helm.sh/helm-v3.22.0-linux-{arch}.tar.gz",
            f"linux-{arch}/helm",
        ),
        "k9s": (
            f"https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_{arch}.tar.gz",
            "k9s",
        ),
        "code-server": (
            f"https://github.com/coder/code-server/releases/download/v4.137.0/code-server-4.137.0-linux-{arch}.tar.gz",
            "*",
        ),
    }
    for name in (("kubectl", "helm", "k9s") if tier == "k8s" else ("code-server",)):
        url, member = specs[name]
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != CHECKSUMS[name][arch]:
            raise SystemExit(f"{name}: checksum mismatch")
        if member == "*":
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                for item in archive.getmembers():
                    # Standalone distribution has one versioned parent directory.
                    item.name = "/".join(Path(item.name).parts[1:])
                    if item.name:
                        archive.extract(item, destination, filter="data")
        else:
            if member:
                with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                    data = archive.extractfile(member).read()
            target = destination / name
            target.write_bytes(data)
            target.chmod(0o755)


if __name__ == "__main__":
    main()
