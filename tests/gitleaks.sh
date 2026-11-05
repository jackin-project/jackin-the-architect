#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
prek_version=$(sed -n 's/^prek = "\([^"]*\)"/\1/p' "$root/mise.toml")
gitleaks_version=$(sed -n 's/^gitleaks = "\([^"]*\)"/\1/p' "$root/mise.toml")
prek_bin=$(mise -C / which prek --tool "prek@$prek_version")
gitleaks_bin=$(mise -C / which gitleaks --tool "gitleaks@$gitleaks_version")
PATH=$(dirname "$gitleaks_bin"):$PATH
export PATH
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

repo=
new_repo() {
    repo=$scratch/$1
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    cp "$root/.pre-commit-config.yaml" "$repo/.pre-commit-config.yaml"
    git -C "$repo" add .pre-commit-config.yaml
    git -C "$repo" commit -qm baseline
}

run_pass() {
    if (cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1); then
        return 0
    fi
    echo "FAIL $1"
    return 1
}

new_repo clean
printf 'clean\n' >"$repo/clean.txt"
git -C "$repo" add clean.txt
run_pass staged_clean_file
printf '.env\n' >"$repo/.gitignore"
printf 'ghp_%s%s\n' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' 'abcdefghijklmnopqrstuvwxyz' >"$repo/.env"
git -C "$repo" add .gitignore
run_pass ignored_untracked_env
echo "ok   staged_clean_file_and_ignored_env"

new_repo option
printf 'clean\n' >"$repo/clean.txt"
git -C "$repo" add clean.txt
run_pass option_baseline
aws_access_key_id=$(printf '%s%s' 'AKIA' 'Z7VRSQ3ABCDEFGHI')
aws_secret=$(printf '%s%s' 'wJalrXUtnFEMI/K7MDENG/' 'bPxRfiCYzZ7K3ABcdE')
printf 'aws_access_key_id = "%s"\naws_secret = "%s"\n' "$aws_access_key_id" "$aws_secret" >"$repo/--exit-code=0"
git -C "$repo" add -f -- --exit-code=0
if (cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1); then
    echo "FAIL leading_dash_secret_passed"
    exit 1
fi
if grep -Fq "$aws_access_key_id" "$scratch/run.out" || grep -Fq "$aws_secret" "$scratch/run.out"; then
    echo "FAIL gitleaks_output_disclosed_value"
    exit 1
fi
echo "ok   leading_dash_secret_rejected"
