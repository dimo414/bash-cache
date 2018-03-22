#!/bin/bash

# Bash-Cache provides a transparent mechanism for caching long-running Bash
# functions. See the README.md for full details.
#
# Originally part of ProfileGem and prompt.gem, this functionality has been
# pulled out into a standalone utility.
# http://hg.mwdiamond.com/profilegem and http://hg.mwdiamond.com/prompt.gem
#

# Given a name and an existing function, create a new function called name that
# executes the same commands as the initial function.
# Used by pgem_decorate.
copy_function() {
  local function="${1:?Missing function}"
  local new_name="${2:?Missing new function name}"
  declare -F "$function" &> /dev/null || {
    echo "No such function ${function}"; return 1
  }
  eval "$(echo "${new_name}()"; declare -f "$function" | tail -n +2)"
}

# Consistently-named md5 operation
# http://stackoverflow.com/q/8996820/113632
# If this still proves insufficient, it might be simpler to outsource to Python
if ! command -v md5sum &> /dev/null && command -v md5 &> /dev/null; then
  md5sum() { md5 "$@"; }
fi

# Given a function - and optionally a list of environment variables - Decorates
# the function with a short-term caching mechanism, useful for improving the
# responsiveness of functions used in the prompt, at the expense of slightly
# stale data.
#
# Suggested usage:
#   expensive_func() {
#     ...
#   } && _cache expensive_func PWD
#
# This will replace expensive_func with a new fuction that caches the result
# of calling expensive_func with the same arguments and in the same working
# directory too often. The original expensive_func can still be called, if
# necessary, as _orig_expensive_func.
#
# Reading/writing output to files is tricky, for a breakdown of the issues see
# http://stackoverflow.com/a/22607352/113632
#
# It'd be nice to do something like write out,err,exit to a single file (e.g.
# base64 encoded, newline separated), but uuencode isn't always installed.
_cache() {
  $ENABLE_CACHED_COMMANDS || return 0

  mkdir -p "$CACHE_DIR"

  func="${1:?"Must provide a function name to cache"}"
  shift
  copy_function "${func}" "_orig_${func}" || return
  local env="${func}:"
  for v in "$@"
  do
    env="$env:\$$v"
  done
  eval "$(cat <<EOF
    _cache_$func() {
      : "\${cachepath:?"Must provide a cachepath to link to as an environment variable"}"
      mkdir -p "\$CACHE_DIR"
      local cmddir=\$(mktemp -d "\$CACHE_DIR/XXXXXXXXXX")
      _orig_$func "\$@" > "\$cmddir/out" 2> "\$cmddir/err"; echo \$? > "\$cmddir/exit"
      # Add end-of-output marker to preserve trailing newlines
      printf "EOF" >> "\$cmddir/out"
      printf "EOF" >> "\$cmddir/err"
      ln -sfn "\$cmddir" "\$cachepath" # atomic
    }
EOF
  )"
  eval "$(cat <<EOF
    $func() {
      \$ENABLE_CACHED_COMMANDS || { _orig_$func "\$@"; return; }
      # Clean up stale caches in the background
      (find "\$CACHE_DIR" -not -path "\$CACHE_DIR" -not -newermt '-1 minute' -delete &)

      local arghash=\$(echo "\${*}::${env}" | md5sum | tr -cd '0-9a-fA-F')
      local cachepath=\$CACHE_DIR/\$arghash

      # Read from cache - capture output once to avoid races
      local out err exit
      out=\$(cat "\$cachepath/out" 2>/dev/null)
      err=\$(cat "\$cachepath/err" 2>/dev/null)
      exit=\$(cat "\$cachepath/exit" 2>/dev/null)
      if [[ "\$exit" == "" ]]; then
        # No cache, execute in foreground
        _cache_$func "\$@"
        out=\$(cat "\$cachepath/out")
        err=\$(cat "\$cachepath/err")
        exit=\$(cat "\$cachepath/exit")
      elif [[ "\$(find "\$CACHE_DIR" -path "\$cachepath/exit" -newermt '-10 seconds')" == "" ]]; then
        # Cache exists but is old, refresh in background
        ( _cache_$func "\$@" & )
      fi
      # Output cached result
      printf "%s" "\${out%EOF}"
      printf "%s" "\${err%EOF}" >&2
      return "\${exit:-255}"
    }
EOF
  )"
}