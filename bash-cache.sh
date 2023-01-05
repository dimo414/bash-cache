#!/bin/bash
#
# Bash Cache provides a transparent mechanism for caching long-running Bash
# functions. See the README.md for full details.
#
# shellcheck disable=SC2317  # Disable this check for now, see shellcheck#2613 and shellcheck#2614

# Configuration
_bc_enabled=true
_bc_version=(0 10 0)

if [[ -n "${BC_HASH_COMMAND:-}" ]]; then
  _bc_hash_command="$BC_HASH_COMMAND"
elif command -v sha1sum &> /dev/null; then
  _bc_hash_command='sha1sum'
elif command -v shasum &> /dev/null; then # OSX
  _bc_hash_command='shasum'
fi

if [[ -n "${_BC_TESTONLY_CACHE_DIR:-}" ]]; then
  _bc_cache_dir="$_BC_TESTONLY_CACHE_DIR"
else
  printf -v _bc_cache_dir '%s/bash-cache-%s.%s-%s' \
    "${BC_CACHE_DIR:-${TMPDIR:-/tmp}}" "${_bc_version[@]::2}" "$EUID"
fi

_bc_locks_dir="${_bc_cache_dir}.locks"
_bc_cleanup_frequency=60


# Ensures the dir exists. If it does not exist creates it and restricts its permissions.
bc::_ensure_dir_exists() {
  local dir=${1:?dir}
  [[ -d "$dir" ]] && return
  mkdir -p "$dir" &&
    # Cache dir should only be accessible to current user
    chmod 700 "$dir"
}

# Hash function used to key cached results.
# We need to avoid munging similar invocations into identical strings to hash
# (e.g. `foo a b` vs. `foo 'a b'` could naively be decomposed to the same
# string). Fortunately, we can safely use NUL as a field delimiter since NUL
# bytes can't appear in Bash strings, meaning it _should_ not be possible for
# different invocations to munge to the same hash input.
bc::_hash() {
  printf '%s\0' "$@" | "${_bc_hash_command:-cksum}" | tr -cd '0-9a-fA-F'
}

# Gets the time of last file modification in seconds since the epoch. Prints 0 and fails if file
# does not exist.
# Implementation is selected dynamically to support different environments (notably BSD/OSX and GNU
# stat have different semantics)
# Found https://stackoverflow.com/a/17907126/113632 after implementing this, could also use date
# as suggested there if these two aren't sufficient.
if stat -c %Y . &> /dev/null; then
  bc::_modtime() { stat -c %Y "$@" 2>/dev/null || { echo 0; return 1; }; } # GNU stat
else
  bc::_modtime() { stat -f %m "$@" 2>/dev/null || { echo 0; return 1; }; } # BSD/OSX stat
fi

# Deletes all symlinks pointing to a nonexistant location
if find /dev/null -xtypex l &> /dev/null; then
  bc::_clear_symlinks() { find "$@" -xtype l -delete; } # GNU find
else
  # https://unix.stackexchange.com/a/38691/19157
  bc::_clear_symlinks() { find "$@" -type l ! -exec test -e {} \; -delete; } # BSD/OSX find
fi

# Writes the current system time in seconds since the epoch to $_now.
# Modern Bash can use the printf builtin, older Bash must call out to date.
if printf '%(%s)T' -1 &> /dev/null; then
  bc::_now() { printf -v _now '%(%s)T' -1; } # Bash 4.2+
else
  bc::_now() { _now=$(date '+%s'); } # Fallback
fi

# Converts a duration, like 10s, 5h, or 7m30s, to a number of seconds
# Supports (s)econds, (m)inutes, (h)ours, and (d)ays.
# This parser is fairly lenient, but the only _supported_ format is:
#   ([0-9]+d)? *([0-9]+h)? *([0-9]+m)? *([0-9]+s)?
# Writes the result $_seconds so callers don't need a subshell
bc::_to_seconds() {
  local input=$* duration=0
  until [[ -z "$input" ]]; do
    if [[ "$input" =~ [[:space:]]*([0-9]+[smhd])$ ]]; then
      input=${input%"${BASH_REMATCH[0]}"}
      local element=${BASH_REMATCH[1]} magnitude
      case "${element: -1}" in # ;& fallthrough added in 4.0, can't use yet
        s) magnitude=1 ;;
        m) magnitude=60 ;;
        h) magnitude=3600 ;;
        d) magnitude=86400 ;;
        *) return 126 ;; # should be unreachable
      esac
      (( duration += magnitude * ${element%?} )) # trim unit with %?
    else
      printf "Invalid duration: '%s' (token: %s)\n" "$*" "${input##* }" >&2
      return 1
    fi
  done
  printf -v _seconds '%s' "$duration"
}

# Succeeds if the given FILE is less than SECONDS old (according to its modtime)
bc::_newer_than() {
  local modtime _now seconds
  modtime=$(bc::_modtime "${1:?Must provide a FILE}") || return
  bc::_now || return
  seconds=${2:?Must provide a number of SECONDS}
  (( modtime > _now - seconds ))
}

# Reads stdin into a variable, accounting for trailing newlines. Avoids needing a subshell or
# command substitution. Although better than a command substitution bc::cache avoids this function
# because NUL bytes are still unsupported, as Bash variables don't allow NULs.
# See https://stackoverflow.com/a/22607352/113632 and https://stackoverflow.com/a/49552002/113632
bc::_read_input() {
  # Use unusual variable names to avoid colliding with a variable name
  # the user might pass in (notably "contents")
  : "${1:?Must provide a variable to read into}"
  if [[ "$1" == '_line' || "$1" == '_contents' ]]; then
    echo "Cannot store contents to $1, use a different name." >&2
    return 1
  fi

  local _line _contents=()
   while IFS='' read -r _line; do
     _contents+=("$_line"$'\n')
   done
   # include $_line once more to capture any content after the last newline
   printf -v "$1" '%s' ${_contents[@]+"${_contents[@]}"} "$_line"
}

# Given a name and an existing function, create a new function called name that
# executes the same commands as the initial function.
bc::copy_function() {
  local function="${1:?Missing function}"
  local new_name="${2:?Missing new function name}"
  declare -F "$function" &> /dev/null || {
    echo "No such function ${function}" >&2; return 1
  }
  eval "$(printf '%q()' "$new_name"; declare -f "$function" | tail -n +2)"
}

# Enables and disables caching - if disabled cached functions delegate directly
# to their bc::orig:: function.
bc::on()  { _bc_enabled=true;  }
bc::off() { _bc_enabled=false; }

# Sets the path to read the cached data from; this will be used as a symlink
# pointing to where the data is written.
# Assumes ${env[@]}, ${func}, and ${args[@]} are set appropriately
bc::_set_cache_read_loc() {
  # NOT local; must be local in calling function
  cache_read_loc="${_bc_cache_dir}/$(bc::_hash ${env[@]+"${env[@]}"} -- "$func" ${args[@]+"${args[@]}"})"
}

# Captures function output and writes to disc
# Assumes ${cache_read_loc}, ${ttl}, ${env[@]}, ${func}, and ${args[@]} are set appropriately
bc::_write_cache() {
  local cache_write_dir="${_bc_cache_dir}/data/${ttl}" cache
  bc::_ensure_dir_exists "$cache_write_dir"
  cache=$(mktemp -d "${cache_write_dir}/XXXXXXXXXX") || return
  "bc::orig::${func}" ${args[@]+"${args[@]}"} > "${cache}/out" 2> "${cache}/err"
  printf '%s' $? > "${cache}/exit"
  ln -sfn "$cache" "$cache_read_loc" # atomic
}

# Triggers a cleanup of stale cache records. By default cleanup runs at most
# once every 60 seconds. If shorter cache expirations are configured cleanups
# will run more frequently.
bc::_cleanup() {
  [[ -d "$_bc_cache_dir" ]] || return
  bc::_newer_than "$_bc_cache_dir/cleanup" "$_bc_cleanup_frequency" && return

  # Basic mutex to prevent concurrent cleanups - BashFAQ/045
  if mkdir "${_bc_cache_dir}/do_cleanup" 2>/dev/null; then
    bc::_do_cleanup 2>/dev/null
    rm -r "${_bc_cache_dir}/do_cleanup"
  fi
}

bc::_do_cleanup() {
  touch "$_bc_cache_dir/cleanup"
  cd / || return # necessary because find will cd back to the cwd, which can fail

  if [[ -d "${_bc_cache_dir}/data" ]]; then
    local dir
    find "${_bc_cache_dir}/data" -maxdepth 1 -mindepth 1 |
      while IFS= read -r dir; do
        find "$dir" -not -path "$dir" -not -newermt "-${dir##*/} seconds" -delete
      done
  fi

  bc::_clear_symlinks "$_bc_cache_dir"
}

# "Decorates" a given function, wrapping it in a caching mechanism to speed up
# repeated invocation (at the expense of potentially-stale data). This behavior
# wass designed to improve the responsiveness of functions used in an
# interactive shell prompt, but can be used anywhere caching would be helpful.
#
# Usage:
#   bc::cache FUNCTION TTL REFRESH [ENV_VARS ...]
#
# FUNCTION     Name of the function to cache
# TTL          The _minimum_ amount of time to cache this function's output. The
#              cache is invalidated asynchronously, so data may sometimes
#              persist longer than this duration.
# REFRESH      The time after which cached data is considered stale; the data
#              will be refreshed asynchronously if the function is called after
#              this much time has passed.
# ENV_VARS ... Names of any environment variables to additionally key the cache
#              on, such as PWD
#
# Durations can be specified in seconds, minutes, hours, and days, e.g. 10m30s
#
# Example usage:
#
#   expensive_func() {
#     ...
#   } && bc::cache expensive_func 1m 10s PWD
#
# This will replace expensive_func with a new function that caches the result
# of calling expensive_func with the same arguments and in the same
# working directory. Data is cached for at least one minute, and will be
# refreshed asynchronously if the function is invoked more than 10 seconds after
# the prior invocation. The original expensive_func is still available as
# bc::orig::expensive_func.
bc::cache() {
  local _seconds func="${1:?"Must provide a function name to cache"}"; shift
  local ttl=60 # legacy support for a default TTL duration, may go away
  if [[ "${1:-}" =~ [0-9]+[dhms]$ ]]; then # safe because variable names can't match this pattern
    bc::_to_seconds "$1" || return; shift
    ttl=$_seconds
  fi
  local refresh=10 # legacy support for a default refresh duration, may go away
  if [[ "${1:-}" =~ [0-9]+[dhms]$ ]]; then # safe because variable names can't match this pattern
    bc::_to_seconds "$1" || return; shift
    refresh=$_seconds
  fi

  if (( refresh > ttl )); then
    printf 'refresh(%ss) cannot exceed TTL(%ss).' "$refresh" "$ttl" >&2
    return 1
  fi

  # run cleanups more frequently if shorter expirations are set
  if (( _bc_cleanup_frequency > ttl )); then
    if (( ttl >= 10 )); then
      _bc_cleanup_frequency="$ttl"
    else
      _bc_cleanup_frequency="10"
    fi
  fi

  local v escaped env=()
  for v in "$@"; do
    # shellcheck disable=SC2016
    printf -v escaped '"${%s:-}"' "$v"
    if ! eval ": ${escaped}" 2>/dev/null; then
      echo "${v} is not a valid variable" >&2
      return 1
    fi
    env+=("$escaped")
  done

  bc::copy_function "${func}" "bc::orig::${func}" || return

  # This is a function-template pattern suggested in #5, in order to reduce
  # the amount of code stored in strings for use by eval. The template bodies
  # are still eval-ed (after replacing placeholders), but this pattern helps
  # isolate the 'dynamic' behavior to those placeholders. The rest of the
  # function body is reused exactly as written, and avoids needing to wrestle
  # with nested quotes/escaping/etc.
  #
  # For now these functions are declared inline and unset after use to avoid
  # polluting the global namespace. It may be better to just declare them as
  # top-level functions and let them live in the global namespace.

  bc::_warm_template() {
    ( {
        local func="%func%" ttl="%ttl%" env=(%env%) args=("$@") cache_read_loc
        bc::_set_cache_read_loc
        bc::_write_cache
       } & )
  }

  # shellcheck disable=SC2288
  bc::_force_template() {
    local func="%func%" ttl="%ttl%" env=(%env%) args=("$@") cache_read_loc
    bc::_set_cache_read_loc
    rm -f "$cache_read_loc" # invalidate the cache
    "%func%" "$@"
  }

  # shellcheck disable=SC2288
  bc::_cache_template() {
    "$_bc_enabled" || { bc::orig::%func% "$@"; return; }
    ( bc::_cleanup & ) # Clean up stale caches in the background

    local func="%func%" ttl="%ttl%" refresh="%refresh%" env=(%env%) args=("$@") exit cache_read_loc
    bc::_set_cache_read_loc

    while true; do
      # Attempt to open the /out and /err files as descriptors 3 and 4; if either fails to open the
      # block does not execute. If they both open successfully the descriptors can be safely read
      # even if the files are concurrently cleaned up.
      # Descriptor 2 (stderr) is bounced to descriptor 5 (in the inner block) and back (in the outer
      # block) so that errors opening either file (in the middle block) can be discarded.
      { { {
        IFS='' read -r exit <"${cache_read_loc}/exit" || true
        # if exit is missing/empty we raced with a cleanup, disregard cache
        if [[ -n "$exit" ]]; then
          if (( refresh > 0 )) && ! bc::_newer_than "${cache_read_loc}/exit" "$refresh"; then
            # Cache exists but is old, refresh in background
            ( bc::_write_cache & )
          fi
          command cat <&3 >&1 # stdout
          command cat <&4 >&2 # stderr
          return "$exit"
        fi
      # Unlike using exec, this syntax preserves any existing file descriptors that might be open.
      # https://mywiki.wooledge.org/FileDescriptor#Juggling_FDs describes this in more detail.
      } 2>&5; } 2>/dev/null 3<"${cache_read_loc}/out" 4<"${cache_read_loc}/err"; } 5>&2 || true

      # No cache, refresh in foreground and try again
      bc::_write_cache
    done
  }

  # shellcheck disable=SC2155
  local warm_function_body=$(declare -f "bc::_warm_template" | tail -n +2)
  # shellcheck disable=SC2155
  local force_function_body=$(declare -f "bc::_force_template" | tail -n +2)
  # shellcheck disable=SC2155
  local cache_function_body=$(declare -f "bc::_cache_template" | tail -n +2)
  unset -f bc::_warm_template bc::_force_template bc::_cache_template
  eval "$(printf 'bc::warm::%q()\n%s ; bc::force::%q()\n%s ; %q()\n%s' \
      "$func" "$warm_function_body" "$func" "$force_function_body" "$func" "$cache_function_body" \
    | sed \
      -e "s/%func%/${func}/g" \
      -e "s/%ttl%/${ttl}/g" \
      -e "s/%refresh%/${refresh}/g" \
      -e "s/%env%/${env[*]:-}/g")"
}

# Further decorates bc::cache with a mutual-exclusion lock. This ensures that
# only one invocation of the original function is being executed at a time, and
# that its result will be cached and used by any blocked concurrent invocations.
#
# Suggested usage:
#   non_idempotent_func() {
#     ...
#   } && bc::locked_cache non_idempotent_func
#
# This will replace non_idempotent_func with a new function that holds a mutex
# lock before invoking bc::cache's caching mechanism.
#
# WARNING: the mutex lock is *advisory*, and may not function correctly on
# some operating systems (where it degrades to bc::cache), or if a caller
# intentionally works around it. If you need to rely on locking for correctness
# prefer to implement appropriate locking yourself.
bc::locked_cache() {
  bc::cache "$@" || return

  if ! command -v flock &> /dev/null; then
    echo "flock not found - bc::locked_cache will not use mutual-exclusion." >&2
    return 1
  fi

  if (( BASH_VERSINFO[0] < 4 )) || (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1 )); then
    # due to the {fd} syntax below, which assigns a free file descriptor to the fd variable
    echo "bc::locked_cache cannot use mutual-exclusion on Bash ${BASH_VERSION}" >&2
    return 2
  fi

  func="${1:?"Should be impossible since bc::cache already completed"}"
  bc::copy_function "${func}" "bc::unlocked::${func}" || return
  unset -f "bc::warm::${func}" || return # locked_cache doesn't support warming

  bc::_ensure_dir_exists "$_bc_locks_dir"
  touch "${_bc_locks_dir}/${func}.lock"

  # shellcheck disable=SC2288
  bc::_locked_template() {
    bc::_ensure_dir_exists "$_bc_locks_dir"
    local fd
    (
      flock "$fd"
      bc::unlocked::%func% "$@"
    # This weird &&%redir% replacement is a hack to allow this template to parse
    # because earlier Bash versions won't even parse a {fd}> redirect.
    ) &&%redir% "${_bc_locks_dir}/%func%.lock"
  }

  # shellcheck disable=SC2155
  local locked_function_body=$(declare -f "bc::_locked_template" | tail -n +2)
  unset -f bc::_locked_template
  eval "$(printf '%q()\n%s' "$func" "$locked_function_body" \
    | sed -e "s/%func%/${func}/g" -e 's/&& %redir%/{fd}>/g')"
}

# A lightweight alternative to bc::cache that attempts to persist repeated calls without disk I/O
# and with weaker guarantees than bc::cache. Unlike bc::cache, memoized functions:
# * Only persist stdout (stderr is untouched, and therefore only printed when the backing function
#   is actually run)
# * Only memoize calls that succeed (0 return code)
# * Only persist a subset of recent invocations (currently just the most recent one)
# * Are only persisted within the current shell (important! see below)
# * Are persisted indefinitely, there is no TTL
#
# It is most useful for idempotent functions that:
# * Are typically called repeatedly with the same arguments/state
# * Don't write to stderr or return non-zero exit codes
# * Don't require TTLs or time-based cache expiry
#
# Although the exact memoization semantics are subject to change (e.g. to improve the hit rate), a
# memoized function will avoid re-invoking the backing function _at least_ when invoked a second
# time with the same arguments and state. Therefore this is most useful for idempotent functions
# that are typically called repeatedly with the same inputs (e.g. a no-arg PWD-sensitive function
# that is called many times from the same directory). Assume that calls with different arguments or
# environment variables invalidates all cached data.
#
# Note that an in-memory cache is incompatible with subshells or command substitutions. If the
# function is cached within a subshell the cached result will _not_ propagate back to the calling
# shell.
#
# Usage:
#   bc::memoize FUNCTION [ENV_VARS ...]
#
# FUNCTION     Name of the function to memoize
# ENV_VARS ... Names of any environment variables to additionally key on,
#              such as PWD
bc::memoize() {
  local func="${1:?"Must provide a function name to memoize"}"; shift

  local v escaped env=()
  for v in "$@"; do
    # shellcheck disable=SC2016
    printf -v escaped '"${%s:-}"' "$v"
    if ! eval ": ${escaped}" 2>/dev/null; then
      echo "${v} is not a valid variable" >&2
      return 1
    fi
    env+=("$v")
  done

  bc::copy_function "${func}" "bc::orig::${func}" || return

  # shellcheck disable=SC2288
  bc::_memoize_template() {
    local output v vars=() check checks=() func
    # Preserve the exit code along with bc::_read_input, similar to proposal in #9. See also
    # https://stackoverflow.com/a/43901140/113632 and Bash 4.2's lastpipe which might work better.
    bc::_read_input output < <(bc::orig::%func% "$@"; printf "%3d" "$?")
    (( ${output: -3} == 0 )) || return "$(( ${output: -3} ))"
    output="${output%???}"
    printf '%s' "$output"

    for (( v=1; v<=$#; v++ )); do vars+=("$v"); done
    vars+=(%env%)
    for v in ${vars[@]+"${vars[@]}"}; do
      # shellcheck disable=SC2016
      printf -v check '&& [[ "${%q:-}" == %q ]]' "$v" "${!v:-}"
      checks+=("$check")
    done

    # shellcheck disable=SC2016
    printf -v func '%q() {
    "$_bc_enabled" || { bc::orig::%q "$@"; return; }
    if (( $# == %q )) %s; then printf "%%s" %q; else bc::memoize::%q "$@"; fi; }' \
     '%func%' '%func%' "$#" "${checks[*]:-}" "$output" '%func%'
    eval "$func"
  }

  # shellcheck disable=SC2155
  local memoize_function_body=$(declare -f "bc::_memoize_template" | tail -n +2)
  unset -f bc::_memoize_template
  eval "$(printf '%q() { bc::memoize::%q "$@"; }\nbc::memoize::%q()\n%s' \
    "$func" "$func" "$func" "$memoize_function_body" \
    | sed \
      -e "s/%func%/${func}/g" \
      -e "s/%env%/${env[*]:-}/g")"
}

# Prints the real-time to execute the given command, discarding its output.
bc::_time() {
  (
    TIMEFORMAT=%R
    time "$@" &> /dev/null
  ) 2>&1
}

# Benchmarks a function, printing the function's raw runtime as well as with a cold and warm cache.
# Runs in a subshell and can be used with any function, whether or not it's been cached already.
bc::benchmark() {
  local func=${1:?Must specify a function to benchmark}
  shift
  if ! declare -F "$func" &> /dev/null; then
    echo "No such function ${func}" >&2
    return 1
  fi
  # Drop into a subshell so the benchmark doesn't affect the calling shell
  (
    _bc_cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/bc-benchmark-XXXXXX") || return

    # Undo the caching if $func has already been cached - no-op otherwise
    bc::copy_function "bc::orig::${func}" "${func}" &> /dev/null || true
    # Cache (or re-cache) the function
    # Doesn't include any env vars in the key, which is probably fine for most benchmarks
    bc::cache "$func" 1m 10s

    local raw cold warm
    raw="$(bc::_time "bc::orig::${func}" "$@")"
    cold="$(bc::_time "$func" "$@")"
    warm="$(bc::_time "$func" "$@")"

    printf 'Benchmarking %s with bc::cache\nOriginal:\t%s\nCold Cache:\t%s\nWarm Cache:\t%s\n' \
    "$func" "$raw" "$cold" "$warm"

    rm -rf "$_bc_cache_dir" # not the "real" cache dir
  )
}

bc::benchmark_memoize() {
  local func=${1:?Must specify a function to benchmark}
  shift
  if ! declare -F "$func" &> /dev/null; then
    echo "No such function ${func}" >&2
    return 1
  fi
  # Drop into a subshell so the benchmark doesn't affect the calling shell
  (
    # Undo the memoizing if $func has already been cached - no-op otherwise
    bc::copy_function "bc::orig::${func}" "${func}" &> /dev/null || true
    # Memoize the function (with special env var)
    bc::memoize "$func" BENCH

    local raw cold warm invalidated
    raw="$(bc::_time "bc::orig::${func}" "$@")"
    cold="$(bc::_time "$func" "$@")"
    # Memoized functions don't share state across subshells, so we need to
    # warm it first within the same command substitution
    warm="$("$func" "$@" &>/dev/null; bc::_time "$func" "$@")"
    invalidated="$("$func" "$@" &>/dev/null; BENCH=1 bc::_time "$func" "$@")"

    printf 'Benchmarking %s with bc::memoize\nOriginal:\t%s\nCold Start:\t%s\nMemoized:\t%s\nInvalidated:\t%s\n' \
      "$func" "$raw" "$cold" "$warm" "$invalidated"
  )
}
