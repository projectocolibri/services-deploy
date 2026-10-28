#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-run}"
case "${command_name}" in
    check|update|run) ;;
    *) echo "Usage: $0 [check|update|run]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="${root}/.version"
cd "${root}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "This deployment directory is not a Git clone. Clone the repository with 'git clone' instead of downloading a ZIP, then run this script again." >&2
    exit 1
fi

git fetch origin --tags --prune

latest="$(
    git tag --list 'v*' |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -V |
        tail -n 1
)"
[ -n "${latest}" ] || {
    echo "No semantic version tags (vMAJOR.MINOR.PATCH) were found." >&2
    exit 1
}

current=""
[ -f "${version_file}" ] && current="$(tr -d '\r\n' < "${version_file}")"
should_run=false
[ "${command_name}" = "run" ] && should_run=true

if [ "${command_name}" = "check" ]; then
    if [ -z "${current}" ]; then
        echo "No deployed version recorded. Latest available: ${latest}"
    elif [ "${current}" = "${latest}" ]; then
        echo "Already running ${current}"
    else
        echo "Update available: ${current} -> ${latest}"
    fi
    exit 0
fi

if [ "${command_name}" = "run" ] && { [ -z "${current}" ] || [ "${current}" != "${latest}" ]; }; then
    if [ -z "${current}" ]; then
        printf 'No deployed version recorded. Deploy %s now? [y/N] ' "${latest}"
    else
        printf 'Update from %s to %s before starting? [y/N] ' "${current}" "${latest}"
    fi
    read -r answer
    if [[ "${answer}" =~ ^[Yy](es)?$ ]]; then
        command_name=update
    else
        [ -n "${current}" ] || {
            echo "Cannot run without a deployed version. Use update or confirm deployment." >&2
            exit 1
        }
        echo "Starting the current version ${current}"
    fi
fi

if [ "${command_name}" = "update" ]; then
    previous="$(git rev-parse --verify HEAD)"
    git reset --hard "${latest}"
    if ! docker compose config --quiet; then
        git reset --hard "${previous}"
        echo "Compose validation failed for ${latest}; restored ${previous}." >&2
        exit 1
    fi
    printf '%s\n' "${latest}" > "${version_file}"
    echo "Updated infrastructure to ${latest}"
fi

docker compose config --quiet
if [ "${should_run}" = true ]; then
    docker compose up -d
    echo "Deployment is running"
fi
