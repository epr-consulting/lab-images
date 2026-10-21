# MyLabSkills lab images

These are the public container images that MyLabSkills lab environments run:
the learner's terminal today, more lab images later. Each image lives in its
own directory and has its own Dockerfile, pinned downloads, smoke test and
CI workflow.

| Directory | Image | Purpose |
| --- | --- | --- |
| [`control/`](control/) | `ghcr.io/epr-consulting/lab-control` | The learner's terminal pod (k8s, docker, linux and dev tiers) |

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

## Adding an image

Create a directory with a `Dockerfile` (pinned by digest and checksum), a
smoke test that runs under the image's security contract, a README and a
workflow modelled on `.github/workflows/control.yml`. Publish as
`ghcr.io/epr-consulting/lab-<name>`.

## License

The build files in this repository are licensed under the Apache License 2.0
([LICENSE](LICENSE)). The tools installed in the images keep their own
licenses.
