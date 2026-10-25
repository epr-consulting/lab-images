# MyLabSkills lab images

These are the public container images MyLabSkills uses for lab environments:
the learner's terminal and the CLIs the lab worker creates environments with
today, more lab images later. Each image lives in its
own directory and has its own Dockerfile, pinned downloads, smoke test and
CI workflow.

| Directory | Image | Purpose |
| --- | --- | --- |
| [`control/`](control/) | `ghcr.io/epr-consulting/lab-control` | The learner's terminal pod (k8s, agent, docker, linux and dev tiers) |
| [`cli/`](cli/) | `ghcr.io/epr-consulting/lab-cli` | The vCluster and Helm CLIs the lab worker runs, rebuilt with a patched Go toolchain |

## Tools, never content

These images contain tools only. Lab questions, expected answers, solutions,
private artifacts and grading logic never go into an image or this
repository; the platform delivers them at run time. That rule is what lets
the images be public and pulled anonymously by digest.

## Publishing and use

- CI builds and smoke-tests every image on native AMD64 and ARM64. Pull
  requests build only; pushes to `main` publish `<tier>-<full-commit-sha>`
  tags.
- Deployments pin the published **manifest digest**, never a tag. The
  MyLabSkills platform selects the digest it runs, and a digest only reaches
  an environment once it is selected there.

## Testing an unpublished image locally

A change can be tested end to end on the MyLabSkills local stack before CI
publishes it. epr-consulting/dev-tools builds the image from this checkout (or a
branch, tag or full commit), runs the tier's smoke test under the control pod's
security contract, and pushes it to a local registry that the local lab node
pulls from by digest, like GHCR. From a dev-tools checkout next to this one:

```sh
task labs:control-image LAB_IMAGES=../lab-images -- k8s     # prints registry.local/epr/lab-control@sha256:<digest>
task labs:override -- control_image=registry.local/epr/lab-control@sha256:<digest>
task dev:up                                                 # the learner's terminal now runs it
task labs:override -- --clear && task dev:up                # back to the pinned image
```

The backend's worker and journey fixtures take the same image with
`LAB_CONTROL_IMAGE=registry.local/epr/lab-control@sha256:<digest>`. The
dev-tools README ("Local images") has the details. Once CI publishes the image,
the platform selects the published digest, the backend pins it, and the local
override is cleared.

## Adding an image

Create a directory with a `Dockerfile` (pinned by digest and checksum), a
smoke test that runs under the image's security contract, a README and a
workflow modelled on `.github/workflows/control.yml`. Publish as
`ghcr.io/epr-consulting/lab-<name>`.

## License

The build files in this repository are licensed under the Apache License 2.0
([LICENSE](LICENSE)). The tools installed in the images keep their own
licenses.
