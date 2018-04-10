#!/bin/bash
#
# Basic benchmark of a no-op function to capture caching overheads.

# shellcheck source=/dev/null
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/bash-cache.sh"

noop() { :; }

echo No-op function
bc::benchmark noop