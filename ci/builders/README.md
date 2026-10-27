# CodeBuild builders

Builder templates are composed by `../infra/root.yaml`. Project-specific runtime
versions belong in each nested stack's `Parameters`; the builder passes them to
CodeBuild environment variables and selects them in `phases.install.runtime-versions`.

## Runtime configuration

| Builder | Node.js default | Python default | Selection |
| --- | --- | --- | --- |
| `mvn-docker-codebuild.yaml` | `20` | `3.12` | `NODE_VERSION` and `PYTHON_VERSION`; existing Java and ARM/image selection are preserved. |
| `multilambda-codebuild.yaml` | `22` | `3.12` | `NODE_VERSION` and `PYTHON_VERSION`; image `aws/codebuild/standard:7.0`. |
| `nodejs-generic-codebuild.yaml` | `20` | Not exposed | `NODE_VERSION`; project override remains available. |
| `nodejs-multilambda-codebuild.yaml` | `18` | Not exposed | `NODE_VERSION`; existing accepted versions and defaults are preserved. |

For example, the `PnInfra` stack selects Node.js `22` and Python `3.12` explicitly.
Maven project entries retain Node.js `20` and Python `3.12`; the Zendesk entry
retains Node.js `18`. A change to a shared default must not silently upgrade
other projects.

The mixed and Maven builders no longer run their own `pyenv install`/`pyenv global`
setup. Runtime version output is retained in the build logs. Selecting native
runtimes does not by itself establish a build-time improvement: compare actual
builds under equivalent conditions.

Check requested versions against the actual image and project requirements.
The image tag alone does not establish which runtime an earlier build selected,
and a Lambda deployment runtime is not automatically the build runtime. The
`pn-infra` private-channel-proxy package declares `node >=24`; successful build
and test execution with the selected Node.js 22 remains to be verified. Do not
treat a package engine declaration alone as proof of a failed historical build.

See [AWS available runtimes](https://docs.aws.amazon.com/codebuild/latest/userguide/available-runtimes.html).

## Repository reference inventory

Inventory date: 2026-10-28. Counts are literal template references in
`ci/infra/root.yaml`, not a census of deployed CodeBuild projects or external
consumers.

| Template | References in root | Runtime/configuration scope |
| --- | ---: | --- |
| `mvn-docker-codebuild.yaml` | 40 | Java plus configurable Node.js/Python. |
| `mvn-jar-codebuild.yaml` | 13 | Existing Java selection; unchanged. |
| `nodejs-multilambda-codebuild.yaml` | 7 | Configurable Node.js. Also referenced once in `ci/infra/multi-lambda.yaml`. |
| `webapp-sonar-codebuild.yaml` | 7 | Delegates to the application's `sonar_buildspec.yaml`. |
| `webapp-standard-codebuild.yaml` | 6 | Delegates to the application's `cra_buildspec.yaml`. |
| `not-compiled-repo-codebuild.yaml` | 3 | Existing builder; unchanged. |
| `artifact-publisher-codebuild.yaml` | 1 | Existing publication path; unchanged. |
| `docker-generic-codebuild.yaml` | 1 | Packages Python functions with `python3`; no explicit Python-version parameter. |
| `multilambda-codebuild.yaml` | 1 | Mixed Node.js/Python functions for `pn-infra`. |
| `nodejs-generic-codebuild.yaml` | 1 | Configurable Node.js. |
| `infra-codebuild.yaml` | 0 | Retirement candidate; external/deployed usage not verified. |
| `nodejs-lambda-codebuild.yaml` | 0 | Retirement candidate; external/deployed usage not verified. |
| `webapp-cypress-codebuild.yaml` | 0 | Retirement candidate; external/deployed usage not verified. |

No repository reference was found for the three retirement candidates in the
inspected YAML, shell, JSON and Markdown sources. This does not authorize removing
them: check external callers, CloudFormation stacks, CodeBuild projects, webhooks
and operating procedures first. Template deletion and AWS resource cleanup are
separate changes.

Docker Python configuration and application-owned webapp runtime configuration
are not completed by the four-builder runtime refactoring. Establish the effective
baseline and application rollout requirements before changing those paths.

## Integration and verification

Publish builder templates and `root.yaml` from one coherent source revision.
`ci/bootstrap/pn-ci-pipeline.yaml` uploads the source templates to S3 at deploy
run order 1, then updates `pn-ci-root` at run order 2.

Before promotion, verify at least a representative standard Maven build, an ARM
Maven build and a mixed Lambda build. Inspect effective Node.js/Python/Java
versions, tests, artifact structure/content and initialization times. Preserve
existing IAM, triggers, image choices and packaging behavior. Static diff review
does not replace these execution checks.
