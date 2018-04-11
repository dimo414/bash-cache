# Bash Cache

Bash Cache provides a transparent mechanism for caching, or memoizing, long-running Bash
functions. Although it can be used for scripting, its primary purpose is to cache the
results of expensive commands for display in your terminal prompt.

Originally part of [ProfileGem](http://hg.mwdiamond.com/profilegem) and
[prompt.gem](http://hg.mwdiamond.com/prompt.gem), this functionality has been pulled out into a
standalone utility.

## Installation

Simply `source bash-cache.sh` into your script or shell.

## Usage

To cache a function pass its name to `bc::cache`. This function
[decorates](https://en.wikipedia.org/wiki/Decorator_pattern) an existing Bash function, wrapping
it with a caching layer that temporarily retains the output and exit status of the backing
function.

By default the cache is keyed off the function arguments (meaning `foo`, `foo bar`, and `foo baz`
are each cached separately).

Data is generally cached for no more than 60 seconds, and the cache is refreshed in the background
if more than 10 seconds old. In the future these values may be configurable.

Cached data **is shared across processes** by default; see below for ways to change this.

Some example usages can be seen in the
[prompt.gem project](https://bitbucket.org/dimo414/prompt.gem/src/default/env_functions.sh).

### Customizing the cache key

If your function depends on additional state, such as the current working directory, you'll want to
ensure the cache is keyed off that state, in addition to the function's arguments. To do so pass
any relevant environment variable names to `bc::cache` after the function name.

* `PWD` is often used in order to cache a function based on the current working directory.
* `$` is less common, but can be used to isolate a function's cache to the current process. Note
  you'll need to single-quote this argument (`'$'`).

### Suggested Usage

You can invoke `bc::cache` at any time, however you're encouraged to do so immediately following
the function definition as a form of self-documentation, similar to
[Python's `@decorator` notation](https://en.wikipedia.org/wiki/Python_syntax_and_semantics#Decorators):

```shell
my_expensive_function() {
  ...
} && bc::cache my_expensive_function PWD
```

Notice in this example `PWD` is specified, meaning the cache will key off the current working
directory in addition to any arguments to the function.

### Performance

The cache is (currently) stored on-disk, which is *much* slower than most simple commands. Generally
speaking functions which benefit from caching are doing disk or network I/O that exceeds the
overhead of reading and writing to the cache.

You should benchmark your functions with and without caching (see `bc::benchmark`) to ensure you see
a meaningful improvement before deciding to enable caching. Caching performance can differ
drastically across machines. Notably, if the cache directory (under `/tmp` or `TMPDIR` by default)
are on a [`tmpfs`](https://en.wikipedia.org/wiki/Tmpfs) or a solid-state drive cache performance
will be significantly better than reading and writing to a spinning disk.

### Calling the original function

If needed, the original function can be invoked via `bc::orig::FUNCTION_NAME` (e.g.
`bc::orig::my_expensive_function`).

### Warming the cache

If you anticipate a function will be called shortly you can warm the cache by calling
`bc::warm::FUNCTION_NAME`. This invokes the function in the background and caches its output.

## Other Functions

### `bc::benchmark`

Benchmarks a function without caching enabled, and with a cold and warm cache. This allows you to
see the overhead introduced by Bash Cache and decide if it's beneficial for your function.

This function runs in a subshell against a clean cache directory, and works for any function - you
do not need to have previously called `bc::cache`.

### `bc::copy_function`

This helper function copies an existing function to a new name. This can be used to decorate or
replace a function by first copying the function and then defining a new function with the original
name. This is how `bc::cache` overwrites the function being decorated.

If desired you can stop caching a particular function by copying the `bc::orig::...` function back
to its original name:

```shell
bc::copy_function bc::orig::my_expensive_function my_expensive_function
```

### `bc::on` and `bc::off`

Enables or disables caching process-wide. If `bc::off` is called all cached functions will delegate
immediately to the original function they decorate and will not attempt to use cached data or
cache new data. Call `bc::on` to re-enable caching.

## Configuration

### Use an isolated cache directory

By default bash-cache stores cached output in a user-specific directory under `/tmp` or the path
specified by `TMPDIR`. To use a different path as the cache root set `BC_CACHE_DIR` before sourcing
`bash-cache.sh`. This is useful if you're using Bash Cache across multiple scripts, as you could
otherwise run into namespace collisions (e.g. two scripts caching different functions with the same
name).

## Copyright and License

Copyright 2012-2018 Michael Diamond

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
