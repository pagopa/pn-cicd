# Local:
# https://stackoverflow.com/questions/21151178/shell-script-to-check-if-specified-git-branch-exists
# test if the branch is in the local repository.
# return 1 if the branch exists in the local, or 0 if not.
function is_in_local() {
    local branch=${1}
    local existed_in_local=$(git branch --list ${branch})

    if [[ -z ${existed_in_local} ]]; then
        echo 0
    else
        echo 1
    fi
}

# Remote:
# Ref: https://stackoverflow.com/questions/8223906/how-to-check-if-remote-branch-exists-on-a-given-remote-repository
# test if the branch is in the remote repository.
# return 1 if its remote branch exists, or 0 if not.
function is_in_remote() {
    local branch=${1}
    local existed_in_remote=$(git ls-remote --heads origin ${branch})

    if [[ -z ${existed_in_remote} ]]; then
        echo 0
    else
        echo 1
    fi
}

function set_default_branch() {
    local repo=${1}
    local branch=${2}
    local current_default_branch=$(gh repo view $repo --json defaultBranchRef | jq -r '.defaultBranchRef.name')
    echo "current_default_branch $current_default_branch"

    if [[ "$branch" == "$current_default_branch" ]]; then
        echo 0
    else
        gh repo edit $repo --default-branch $branch
        echo $?
    fi
}

function set_protect_branches() {
    local name=${1}
    local branch=${2}
    local owner="pagopa"

    PROTECTED=$(gh api /repos/${owner}/${name}/branches/${branch} | jq .protected )
    if [[ "$PROTECTED" == "true" ]]; then
        echo "Branch ${branch} already protected"
        return
    fi
    repositoryId="$(gh api graphql -f query='{repository(owner:"'$owner'",name:"'$name'"){id}}' -q .data.repository.id)"

    gh api graphql -f query='
    mutation($repositoryId:ID!,$branch:String!,$requiredReviews:Int!) {
    createBranchProtectionRule(input: {
        repositoryId: $repositoryId
        pattern: $branch
        requiresApprovingReviews: true
        requiredApprovingReviewCount: $requiredReviews
    }) { clientMutationId }
    }' -f repositoryId="$repositoryId" -f branch="${branch}" -F requiredReviews=1 --silent
}