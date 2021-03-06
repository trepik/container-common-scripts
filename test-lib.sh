#
# Test a container image.
#
# Always use sourced from a specific container testfile 
#
# reguires definition of CID_FILE_DIR
# CID_FILE_DIR=$(mktemp --suffix=<container>_test_cidfiles -d)
# reguires definition of TEST_LIST 
# TEST_LIST="\
# ctest_container_creation
# ctest_doc_content"

# Container CI tests
# abbreviated as "ct"

# may be redefined in the specific container testfile
EXPECTED_EXIT_CODE=0

# ct_cleanup
# --------------------
# Cleans up containers used during tests. Stops and removes all containers
# referenced by cid_files in CID_FILE_DIR. Dumps logs if a container exited
# unexpectedly. Removes the cid_files and CID_FILE_DIR as well.
# Uses: $CID_FILE_DIR - path to directory containing cid_files
# Uses: $EXPECTED_EXIT_CODE - expected container exit code
function ct_cleanup() {
  for cid_file in $CID_FILE_DIR/* ; do
    local container=$(cat $cid_file)

    : "Stopping and removing container $container..."
    docker stop $container
    exit_status=$(docker inspect -f '{{.State.ExitCode}}' $container)
    if [ "$exit_status" != "$EXPECTED_EXIT_CODE" ]; then
      : "Dumping logs for $container"
      docker logs $container
    fi
    docker rm -v $container
    rm $cid_file
  done
  rmdir $CID_FILE_DIR
  : "Done."
}

# ct_enable_cleanup
# --------------------
# Enables automatic container cleanup after tests.
function ct_enable_cleanup() {
  trap ct_cleanup EXIT SIGINT
}

# ct_get_cid [name]
# --------------------
# Prints container id from cid_file based on the name of the file.
# Argument: name - name of cid_file where the container id will be stored
# Uses: $CID_FILE_DIR - path to directory containing cid_files
function ct_get_cid() {
  local name="$1" ; shift || return 1
  echo $(cat "$CID_FILE_DIR/$name")
}

# ct_get_cip [id]
# --------------------
# Prints container ip address based on the container id.
# Argument: id - container id
function ct_get_cip() {
  local id="$1" ; shift
  docker inspect --format='{{.NetworkSettings.IPAddress}}' $(ct_get_cid "$id")
}

# ct_wait_for_cid [cid_file]
# --------------------
# Holds the execution until the cid_file is created. Usually run after container
# creation.
# Argument: cid_file - name of the cid_file that should be created
function ct_wait_for_cid() {
  local cid_file=$1
  local max_attempts=10
  local sleep_time=1
  local attempt=1
  local result=1
  while [ $attempt -le $max_attempts ]; do
    [ -f $cid_file ] && [ -s $cid_file ] && return 0
    : "Waiting for container start..."
    attempt=$(( $attempt + 1 ))
    sleep $sleep_time
  done
  return 1
}

# ct_assert_container_creation_fails [container_args]
# --------------------
# The invocation of docker run should fail based on invalid container_args
# passed to the function. Returns 0 when container fails to start properly.
# Argument: container_args - all arguments are passed directly to dokcer run
# Uses: $CID_FILE_DIR - path to directory containing cid_files
function ct_assert_container_creation_fails() {
  local ret=0
  local max_attempts=10
  local attempt=1
  local cid_file=assert
  set +e
  local old_container_args="${CONTAINER_ARGS-}"
  CONTAINER_ARGS="$@"
  ct_create_container $cid_file
  if [ $? -eq 0 ]; then
    local cid=$(ct_get_cid $cid_file)

    while [ "$(docker inspect -f '{{.State.Running}}' $cid)" == "true" ] ; do
      sleep 2
      attempt=$(( $attempt + 1 ))
      if [ $attempt -gt $max_attempts ]; then
        docker stop $cid
        ret=1
        break
      fi
    done
    exit_status=$(docker inspect -f '{{.State.ExitCode}}' $cid)
    if [ "$exit_status" == "0" ]; then
      ret=1
    fi
    docker rm -v $cid
    rm $CID_FILE_DIR/$cid_file
  fi
  [ ! -z $old_container_args ] && CONTAINER_ARGS="$old_container_args"
  set -e
  return $ret
}

# ct_create_container [name, command]
# --------------------
# Creates a container using the IMAGE_NAME and CONTAINER_ARGS variables. Also
# stores the container id to a cid_file located in the CID_FILE_DIR, and waits
# for the creation of the file.
# Argument: name - name of cid_file where the container id will be stored
# Argument: command - optional command to be executed in the container
# Uses: $CID_FILE_DIR - path to directory containing cid_files
# Uses: $CONTAINER_ARGS - optional arguments passed directly to docker run
# Uses: $IMAGE_NAME - name of the image being tested
function ct_create_container() {
  local cid_file="$CID_FILE_DIR/$1" ; shift
  # create container with a cidfile in a directory for cleanup
  docker run --cidfile="$cid_file" -d ${CONTAINER_ARGS:-} $IMAGE_NAME "$@"
  ct_wait_for_cid $cid_file || return 1
  : "Created container $(cat $cid_file)"
}

# ct_scl_usage_old [name, command, expected]
# --------------------
# Tests three ways of running the SCL, by looking for an expected string
# in the output of the command
# Argument: name - name of cid_file where the container id will be stored
# Argument: command - executed inside the container
# Argument: expected - string that is expected to be in the command output
# Uses: $CID_FILE_DIR - path to directory containing cid_files
# Uses: $IMAGE_NAME - name of the image being tested
function ct_scl_usage_old() {
  local name="$1"
  local command="$2"
  local expected="$3"
  local out=""
  : "  Testing the image SCL enable"
  out=$(docker run --rm ${IMAGE_NAME} /bin/bash -c "${command}")
  if ! echo "${out}" | grep -q "${expected}"; then
    echo "ERROR[/bin/bash -c "${command}"] Expected '${expected}', got '${out}'"
    return 1
  fi
  out=$(docker exec $(ct_get_cid $name) /bin/bash -c "${command}" 2>&1)
  if ! echo "${out}" | grep -q "${expected}"; then
    echo "ERROR[exec /bin/bash -c "${command}"] Expected '${expected}', got '${out}'"
    return 1
  fi
  out=$(docker exec $(ct_get_cid $name) /bin/sh -ic "${command}" 2>&1)
  if ! echo "${out}" | grep -q "${expected}"; then
    echo "ERROR[exec /bin/sh -ic "${command}"] Expected '${expected}', got '${out}'"
    return 1
  fi
}

# ct_doc_content_old [strings]
# --------------------
# Looks for occurence of stirngs in the documentation files and checks
# the format of the files. Files examined: help.1
# Argument: strings - strings expected to appear in the documentation
# Uses: $IMAGE_NAME - name of the image being tested
function ct_doc_content_old() {
  local tmpdir=$(mktemp -d)
  local f
  : "  Testing documentation in the container image"
  # Extract the help files from the container
  for f in help.1 ; do
    docker run --rm ${IMAGE_NAME} /bin/bash -c "cat /${f}" >${tmpdir}/$(basename ${f})
    # Check whether the files contain some important information
    for term in $@ ; do
      if ! cat ${tmpdir}/$(basename ${f}) | grep -F -q -e "${term}" ; then
        echo "ERROR: File /${f} does not include '${term}'."
        return 1
      fi
    done
  done
  # Check whether the files use the correct format
  if ! file ${tmpdir}/help.1 | grep -q roff ; then
    echo "ERROR: /help.1 is not in troff or groff format"
    return 1
  fi
  : "  Success!"
}

# ct_run_test_list
# --------------------
# Execute the tests specified by TEST_LIST
# Uses: $TEST_LIST - list of test names
function ct_run_test_list() {
  for test_case in $TEST_LIST; do
    : "Running test $test_case"
    [ -f test/$test_case ] && source test/$test_case
    [ -f ../test/$test_case ] && source ../test/$test_case
    $test_case
  done;
}

