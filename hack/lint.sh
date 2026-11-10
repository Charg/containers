#!/usr/bin/env bash
# Lints the repo: shellcheck over every script, hadolint over every Dockerfile, actionlint, yamllint.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools shellcheck hadolint actionlint yamllint git

cd "${REPO_ROOT}"

echo "==> shellcheck"
git ls-files -z -- '*.sh' | xargs -0 -r shellcheck --external-sources --source-path=SCRIPTDIR

echo "==> hadolint"
git ls-files -z -- '*Dockerfile' | xargs -0 -r hadolint

echo "==> actionlint"
actionlint

echo "==> yamllint"
yamllint --strict .
