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
    "kubectl-ai": {
        "amd64": "872ef891232b01772c46a54b1866b383e043100e3806835158187c603eb490d1",
        "arm64": "c2eb7fb99bf5217968a505ab38b0a230d86d1581957ccdda66167020b114d90d",
    },
    "k8sgpt": {
        "amd64": "e56b5cbe826dbf1e314075453105426acca2ad4410e64073d665c697c97208ed",
        "arm64": "9d8b16ae8c2b1b5527bb2f705e916dc76df9d81179cf67e38f1572846015777e",
    },
    "kubernetes-mcp-server": {
        "amd64": "d791c22b5367813cc9e7c66e405d8ff7f7d51189b5bd619fdd84a99cf7a1c116",
        "arm64": "d9378039b68b5247796655ba8bbb210d5e94287e56bd532112d81950a19f0e50",
    },
    "code-server": {
        "amd64": "9303165b7fd43532091922f77e2f119ff2fa109c6b6f1c3c966fb02f3d6d9c8b",
        "arm64": "0fba760298fe06480d940e218f0873a645ba1e7e3ac4b527059af82d85a90462",
    },
}

K8S_TOOLS = ("kubectl", "helm", "k9s")
TOOLS = {
    "k8s": K8S_TOOLS,
    "agent": K8S_TOOLS + ("kubectl-ai", "k8sgpt", "kubernetes-mcp-server"),
    "dev": ("code-server",),
}


def main():
    tier, arch, destination = sys.argv[1:]
    if arch not in ("amd64", "arm64") or tier not in ("k8s", "agent", "dev"):
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
        "kubectl-ai": (
            f"https://github.com/GoogleCloudPlatform/kubectl-ai/releases/download/v0.0.31/kubectl-ai_Linux_{'x86_64' if arch == 'amd64' else arch}.tar.gz",
            "kubectl-ai",
        ),
        "k8sgpt": (
            f"https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.4.41/k8sgpt_Linux_{'x86_64' if arch == 'amd64' else arch}.tar.gz",
            "k8sgpt",
        ),
        "kubernetes-mcp-server": (
            f"https://github.com/containers/kubernetes-mcp-server/releases/download/v0.0.67/kubernetes-mcp-server-linux-{arch}",
            None,
        ),
        "code-server": (
            f"https://github.com/coder/code-server/releases/download/v4.137.0/code-server-4.137.0-linux-{arch}.tar.gz",
            "*",
        ),
    }
    for name in TOOLS[tier]:
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
