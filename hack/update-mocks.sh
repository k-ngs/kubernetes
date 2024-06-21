#!/usr/bin/env bash

# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script generates mock files using mockgen.
# Usage: `hack/update-mocks.sh`.

set -o errexit
set -o nounset
set -o pipefail

KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
source "${KUBE_ROOT}/hack/lib/init.sh"

kube::golang::setup_env

echo 'installing mockery'
go -C "${KUBE_ROOT}/hack/tools" install github.com/vektra/mockery/v2

function git_grep() {
  git grep --untracked --exclude-standard \
      "$@" \
      ':!:vendor/*'        `# catches vendor/...` \
      ':!:*/vendor/*'      `# catches any subdir/vendor/...` \
      ':!:third_party/*'   `# catches third_party/...` \
      ':!:*/third_party/*' `# catches third_party/...` \
      ':!:*/testdata/*'    `# catches any testdata` \
      ':(glob)**/*.go'
}

cd "${KUBE_ROOT}"

GENERATED_MOCK_FILE_REGEX="^// Code generated by mockery v[0-9.]\+. DO NOT EDIT.$"

# pick a tempfile path for writing to
tmp=$(mktemp)
kube::util::trap_add "rm -f ${tmp:?}" EXIT

git_grep -l -z "${GENERATED_MOCK_FILE_REGEX}" | xargs -0 rm -f

echo 'executing go generate command on below files'

git_grep -l -z "//go:generate mockery" | while read -r -d $'\0' file; do
  echo "- ${file}"
  temp_file_name="$(kube::realpath "$(mktemp -t "$(basename "$0").XXXXXX")")"

  # search for build tag used in file
  build_tag_string=$(grep -o '+build.*$' "$file") || true

  # if the file does not have build string
  if [ -n "$build_tag_string" ]; then
    # write the build tag in the temp file
    echo -n "$build_tag_string" > "$temp_file_name"

    # if +build tag is defined in interface file
    BUILD_TAG_FILE=$temp_file_name go generate -v "$file"
  else
    # if no +build tag is defined in interface file
    # NOTE: This works around a bug in `go generate` with workspaces, which
    # should be fixed in Go 1.22.1.
    go -C "$(dirname "$file")" generate "$(basename "$file")"
  fi
done

# get the changed or new mock files
git ls-files -mo --exclude-standard -z | while read -r -d $'\0' file; do
  # only process files that appear to be mocks
  test -f "$file" || continue
  grep -q "${GENERATED_MOCK_FILE_REGEX}" "$file" || continue

  # search for build tags used in file
  # //go:build !providerless
  # // +build !providerless
  go_build_tag_string=$(grep -o 'go:build.*$' "$file") || true
  build_tag_string=$(grep -o '+build.*$' "$file") || true
  new_header=''

  # if the file has both headers
  if [ -n "$build_tag_string" ] && [ -n "$go_build_tag_string" ]
  then
    # create a new header with the build string and the copyright text
    new_header=$(echo -e "//""$go_build_tag_string""\n""//" "$build_tag_string""\n" | cat - hack/boilerplate/boilerplate.generatego.txt)

    # ignore the first line (build tag) from the file
    tail -n +3 "$file" >"${tmp}"
  fi

  # if the file has only // +build !providerless header
  if [ -n "$build_tag_string" ] && [ -z "$go_build_tag_string" ]
  then
    # create a new header with the build string and the copyright text
    new_header=$(echo -e "//" "$build_tag_string""\n" | cat - hack/boilerplate/boilerplate.generatego.txt)

    # ignore the first line (build tag) from the file
    tail -n +2 "$file" >"${tmp}"
  fi

  # if the file has only //go:build !providerless header
  if [ -z "$build_tag_string" ] && [ -n "$go_build_tag_string" ]
  then
    # create a new header with the build string and the copyright text
    new_header=$(echo -e "//""$go_build_tag_string""\n" | cat - hack/boilerplate/boilerplate.generatego.txt)

    # ignore the first line (build tag) from the file
    tail -n +2 "$file" >"${tmp}"
  fi

  # if the header is generated
  if [ -n "$new_header" ]
  then
    # write the newly generated header file to the original file
    echo -e "$new_header" | cat - "${tmp}" > "$file"
  else
    # if no build string insert at the top
    cat hack/boilerplate/boilerplate.generatego.txt "$file" >"${tmp}" && \
    mv "${tmp}" "$file"
  fi
done
