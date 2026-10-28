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
| `docker-generic-codebuild.yaml` | Not exposed | `3.10` | `PYTHON_VERSION`; image `aws/codebuild/standard:6.0` is unchanged. |
| `webapp-standard-codebuild.yaml` / `webapp-sonar-codebuild.yaml` | `22` | Not exposed | `NODE_VERSION`; selected by the application-owned buildspec. |

The mixed builder defaults to Node.js `22` and accepts `18`, `20`, `22` and `24`.
The `PnInfra` stack selects Node.js `24` and Python `3.12` explicitly; this
project override does not change the shared default or other project versions.
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
`pn-infra` private-channel-proxy package declares `node >=24`; its project-level
Node.js `24` selection aligns with that declaration. Successful builds, tests
and artifact compatibility still need execution evidence. The shared default
`22` is the PN-21579 requirement; the `PnInfra` override is a separately approved
project choice, not a general runtime upgrade required by the epic. Do not treat
a package engine declaration alone as proof of a failed historical build.

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
| `docker-generic-codebuild.yaml` | 1 | Configurable Python for packaging functions; PnSimulatoreRecapitiCI selects 3.10. |
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

The webapp projects explicitly select Node.js 22, matching the updated develop
buildspecs in pn-frontend, pn-showcase-site and pn-helpdesk-fe. Each buildspec
retains a NODE_VERSION fallback of 22 for projects without an environment override.
The CodeBuild project environment overrides that fallback. Runtime logging is
performed before the existing build commands; application dependencies are unchanged.

Docker Python 3.10 matches the published standard:6.0 image default, not a measured
historical execution. It is independent of the application's Docker/Lambda runtime.

## Integration and verification

Integrate the backward-compatible application buildspec changes before changing
the webapp project parameters. Existing projects still select Node.js 22 through
the fallback; later project overrides are consumed by the updated buildspecs.

Publish builder templates and `root.yaml` from one coherent source revision.
`ci/bootstrap/pn-ci-pipeline.yaml` uploads the source templates to S3 at deploy
run order 1, then updates `pn-ci-root` at run order 2.

Before promotion, verify at least a representative standard Maven build, an ARM
Maven build and a mixed Lambda build. Inspect effective Node.js/Python/Java
versions, tests, artifact structure/content and initialization times. Preserve
existing IAM, triggers, image choices and packaging behavior. Static diff review
does not replace these execution checks.
