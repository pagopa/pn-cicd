# cleanup (profile, region, prefix)
cleanup () {
  stacks=$(aws cloudformation --profile $1 list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?starts_with(StackName, \`$3\`) == \`true\`].StackName" --output text --region $2)
  for stack in $stacks
  do
    echo "${stack}: cleaning up change sets"
    changesets=$(aws cloudformation --profile $1 list-change-sets --stack-name $stack --query 'Summaries[?Status==`FAILED`].ChangeSetId' --output text --region $2)
    for changeset in $changesets
    do
      echo "${stack}: deleting change set ${changeset}"
      aws cloudformation --profile $1 delete-change-set --change-set-name ${changeset} --region $2
    done
  done
}

cleanup $1 $2 $3