#!/usr/bin/env bash -x

source ./pn-projects.sh
source ./libs/branches.sh

CURR_DIR=$PWD
DEST_DIR=$CURR_DIR/dependency-check-report
mkdir -p $DEST_DIR
TMP_DIR=$(mktemp -d)
pushd $TMP_DIR

for PRJ in ${BE_PROJECTS[@]}; do
    echo "start $PRJ"
    git clone $GH_PREFIX/$PRJ
    pushd $PRJ
    localDevBranch=$(is_in_local develop)
    if [[ $localDevBranch -eq 0 ]]; then
        git checkout -b develop
    fi
    if [[ " ${BE_MVN_COMMON_PROJECTS[*]} " =~ " ${PRJ} " ]]; then
      ./mvnw install -Dmaven.test.skip=true
    fi
    ./mvnw org.owasp:dependency-check-maven:7.4.1:check -Dformat=ALL
    for CURR_REPORT in $( ls target/dependency-check-report.* ); do
      DEST_REPORT=${PRJ}${CURR_REPORT#target/dependency-check}
      cp $CURR_REPORT $DEST_DIR/$DEST_REPORT
    done;
    popd
    echo "end $PRJ"
done
popd
rm -rf $TMP_DIR

echo "merge report"

cat $DEST_DIR/*.csv | sort -u >$DEST_DIR/merge-report.csv