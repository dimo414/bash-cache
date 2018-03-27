#!/bin/bash

# Bash Cache provides a transparent mechanism for caching long-running Bash
# functions. See the README.md for full details.

# Configuration
_bc_cache_dir="${TMPDIR:-/tmp}/bash-cache"
_bc_enabled=true
_bc_version=(0 1 0)
: $_bc_enabled # satisfy SC2034
: ${#_bc_version} # satisfy SC2034

mkdir -p "$_bc_cache_dir"

# Hash function used to key cached results. Implementation is selected
# dynamically to support different environments (notably OSX provides shasum
# instead of GNU's sha1sum).
if command -v sha1sum &> /dev/null; then
  bc::_hash() { sha1sum <<<"$*"; }
elif command -v shasum &> /dev/null; then
  bc::_hash() { shasum <<<"$*"; }
else
  bc::_hash() { cksum <<<"$*"; }
fi

# Given a name and an existing function, create a new function called name that
# executes the same commands as the initial function.
bc::copy_function() {
  local function="${1:?Missing function}"
  local new_name="${2:?Missing new function name}"
  declare -F "$function" &> /dev/null || {
    echo "No such function ${function}" >&2; return 1
  }
  eval "$(printf "%s()" "$new_name"; declare -f "$function" | tail -n +2)"
}

# Enables and disables caching - if disabled cached functions delegate directly
# to their bc::orig:: function.
bc::on()  { _bc_enabled=true;  }
bc::off() { _bc_enabled=false; }


# Given a function - and optionally a list of environment variables - Decorates
# the function with a short-term caching mechanism, useful for improving the
# responsiveness of functions used in the prompt, at the expense of slightly
# stale data.
#
# Suggested usage:
#   expensive_func() {
#     ...
#   } && bc::cache expensive_func PWD
#
# This will replace expensive_func with a new fuction that caches the result
# of calling expensive_func with the same arguments and in the same working
# directory too often. The original expensive_func can still be called, if
# necessary, as bc::orig::expensive_func.
#
# Reading/writing output to files is tricky, for a breakdown of the issues see
# http://stackoverflow.com/a/22607352/113632
#
# It'd be nice to do something like write out,err,exit to a single file (e.g.
# base64 encoded, newline separated), but uuencode isn't always installed.
bc::cache() {
  func="${1:?"Must provide a function name to cache"}"
  shift
  bc::copy_function "${func}" "bc::orig::${func}" || return
  local env="${func}:"
  for v in "$@"
  do
    env="$env:\$$v"
  done
  eval "$(cat <<EOF
    bc::_cache::$func() {
      : "\${cachepath:?"Must provide a cachepath to link to as an environment variable"}"
      mkdir -p "\$_bc_cache_dir"
      local cmddir
      cmddir=\$(mktemp -d "\$_bc_cache_dir/XXXXXXXXXX") || return
      bc::orig::$func "\$@" > "\$cmddir/out" 2> "\$cmddir/err"; echo \$? > "\$cmddir/exit"
      # Add end-of-output marker to preserve trailing newlines
      printf "EOF" >> "\$cmddir/out"
      printf "EOF" >> "\$cmddir/err"
      ln -sfn "\$cmddir" "\$cachepath" # atomic
    }
EOF
  )"
  eval "$(cat <<EOF
    $func() {
      \$_bc_enabled || { bc::orig::$func "\$@"; return; }
      # Clean up stale caches in the background
      (find "\$_bc_cache_dir" -not -path "\$_bc_cache_dir" -not -newermt '-1 minute' -delete &)

      local arghash cachepath
      arghash=\$(bc::_hash "\${*}::${env}" | tr -cd '0-9a-fA-F')
      cachepath=\$_bc_cache_dir/\$arghash

      # Read from cache - capture output once to avoid races
      local out err exit
      out=\$(cat "\$cachepath/out" 2>/dev/null) || true
      err=\$(cat "\$cachepath/err" 2>/dev/null) || true
      exit=\$(cat "\$cachepath/exit" 2>/dev/null) || true

      if [[ "\$exit" == "" ]]; then
        # No cache, execute in foreground
        bc::_cache::$func "\$@"
        out=\$(cat "\$cachepath/out")
        err=\$(cat "\$cachepath/err")
        exit=\$(cat "\$cachepath/exit")
      elif [[ "\$(find "\$_bc_cache_dir" -path "\$cachepath/exit" -newermt '-10 seconds')" == "" ]]; then
        # Cache exists but is old, refresh in background
        ( bc::_cache::$func "\$@" & )
      fi

      # Output cached result
      printf "%s" "\${out%EOF}"
      printf "%s" "\${err%EOF}" >&2
      return "\${exit:-255}"
    }
EOF
  )"
}