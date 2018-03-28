#!/bin/bash
#
# Runs shellcheck on the functions bash-cache.sh dynamically generates.
#
# Note that inline comments are not preserved making it difficult to suppress warnings. It may be
# necessary to manipulate dynamic.sh before invoking shellcheck.

DIR="${TMPFILE:-/tmp}/bash-cache-test"
mkdir "$DIR"
trap 'rm -rf "$DIR"' EXIT

# https://stackoverflow.com/a/246128/113632
# shellcheck source=/dev/null
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/bash-cache.sh"

declare -F | cut -d' ' -f3 | sort > "$DIR/orig_func.txt"

foobar() { :; }

bc::cache foobar

#declare -F | sort > "$DIR/new_func.txt"


printf "Checking dynamic functions:"
printf '#!/bin/bash\n' > "$DIR/dynamic.sh"
# shellcheck disable=SC2016
printf '_bc_cache_dir=$1\n_bc_enabled=$2\n' >> "$DIR/dynamic.sh" # declare config variables
for func in $(comm -13 "$DIR/orig_func.txt" <(declare -F | cut -d' ' -f3 | sort)); do
  printf " %s" "$func"
  echo >> "$DIR/dynamic.sh"
  type "$func" | tail -n+2 >> "$DIR/dynamic.sh"
done
echo

shellcheck "$DIR/dynamic.sh"
shellcheck_code=$?

if (( shellcheck_code != 0 )); then
  printf '%s\n\n' '--------------------'
  nl -ba "$DIR/dynamic.sh"
  exit $shellcheck_code
fi