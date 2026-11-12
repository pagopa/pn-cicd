# Infra and multilambda releases

The manual **Create Infra and Multilambda Release** workflow in `pn-cicd`
creates RC tags and final GitHub Releases without Maven or AWS credentials.
The [Java release workflow](../.github/workflows/create-java-release.yml)
remains unchanged.

## Onboarding

Supported targets are defined in the `repository` choices of the
[workflow](../.github/workflows/create-infra-multilambda-release.yml).
To onboard a new infrastructure or multilambda repository, add its
`pagopa/<name>` to that list in `pn-cicd`. The script validates the repository
format and the target origin, without duplicating the supported-target list;
no script change is required. Direct script invocation is not an allowlist
or an authorization boundary: repository eligibility is selected by the
workflow, and access is controlled by the bot token and repository protections.

Before using the workflow, explicitly add a regular root `VERSION` file to
the target's development branch. Choose its value from that repository's
actual release cycle; do not assign the same initial version to every target.
For example, `2.5.0-SNAPSHOT` denotes development towards `2.5.0`.
No `VERSION` file is created automatically. Individual Lambda package versions
and lockfiles remain independent.

The automation must be available on the workflow's default branch before it
can be dispatched normally. `GITBOT_TOKEN_FOR_RELEASE` must have access to the
target repositories and permission to publish the intended branches, tags
and Releases. Check repository protections and organization rules first;
do not bypass required reviews or checks.

## Inputs

| Input | Meaning | Default |
| --- | --- | --- |
| `repository` | One supported target, including `pagopa/` | First choice |
| `tag` | `X.Y.Z-RC.N` or `X.Y.Z`, without `v` | Required |
| `base_branch` | Source for RC updates and next-release | `develop` |
| `merge_in_main` | Merge final content into main before tagging | `true` |
| `increment_snapshot` | Prepare the next minor SNAPSHOT | `false` |

Version components are nonnegative decimal integers without leading zeros;
RC numbers are positive. VERSION accepts the same forms plus
`X.Y.Z-SNAPSHOT`. Its base version must match the requested cycle.
Historical `X.Y.Z-RC-N` VERSION values and tags are also recognized for
finalization and RC-number checks; new RCs always use `X.Y.Z-RC.N`.
Finalization does not require develop to remain on the old version unless
preparing a next cycle that is incompatible with its current VERSION.

## Release candidate

Dispatch with, for example, `tag=2.5.0-RC.1`.

1. Validate inputs, VERSION, refs and tag uniqueness.
2. Create `release/2.5.0` from the selected base, or merge that base into the
   existing release branch. Conflicts stop the run before publication.
3. Set VERSION to `2.5.0-RC.1`, commit and create annotated tag `v2.5.0-RC.1`.
4. Publish refs atomically. No GitHub prerelease is created.

After fixes on the selected base, request a higher RC number, for example
`2.5.0-RC.2`. Both historical RC separators are counted when checking that
the number increases. Published tags are never overwritten.

## Final release

After validating the RC, dispatch with `tag=2.5.0`.

The release branch must still point to the latest published RC. Changes
since that RC require another RC. The workflow only updates VERSION to
`2.5.0`; it never imports new changes from develop during finalization.

With `merge_in_main=true`, it prepares a merge into main and verifies that
the result has exactly the final release content. Conflicts or extra main
content stop publication. With `false`, the final tag targets the release
branch commit instead. In both cases the workflow creates `v2.5.0` and a
GitHub Release with generated notes at the verified SHA.

VERSION changes and merges mean that final and RC commits, and potentially
their packaged artifacts, are different. Validate final artifacts before
promotion; a successful GitHub Release is not evidence that CI or deployment
succeeded.

## Next development cycle

With `increment_snapshot=true`, prepare `next-release` from the selected base
with VERSION `2.6.0-SNAPSHOT` for any `2.5.Z` release or RC. This increments
the minor version and resets the patch to zero.

An existing compatible next-release is left unchanged; an incompatible one
stops the run before publishing any refs. Integration of next-release into
develop is manual. The workflow never pushes directly to develop.

## Failure, concurrency and pipeline effects

Runs are serialized per target repository. Immediately before publication,
the workflow rechecks relevant remote refs. The Git push includes the release
branch, tag and any main/next-release updates in one atomic operation, without
force. A rejected or unsupported atomic push is not retried non-atomically.

Creating the GitHub Release is a separate API operation. If that fails after
the push, the Git refs may already exist. The failed run reports the phase,
attempted refs and confirmed publication status. Inspect the repository and
Release before recovering manually; do not delete/repoint tags or blindly
rerun. A repeated request for an existing tag fails explicitly.

Existing branch webhooks may build the published commits. This workflow
does not start CodeBuild, deploy, edit `pn-configuration`, or rebuild artifacts
for environment promotion. Confirm actual CI/CD selectors before first use;
merging onboarding or next-release into develop may trigger existing dev CD.

## Local checks

```sh
bash -n .github/scripts/create-infra-multilambda-release.sh
bash .github/scripts/tests/create-infra-multilambda-release.test.sh
```

Tests use isolated Git fixtures and network-command stubs. They do not
contact GitHub or AWS and do not publish remote refs.
