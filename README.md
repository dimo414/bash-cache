# Bash Cache

Bash Cache provides a transparent mechanism for caching, or memoizing,
long-running Bash functions.

Originally part of [ProfileGem](http://hg.mwdiamond.com/profilegem) and
[prompt.gem](http://hg.mwdiamond.com/prompt.gem), this functionality has been
pulled out into a standalone utility.

## Installation

Simply `source bash-cache.sh` into your script or shell.

## Functions

### `bc::cache`

This function [decorates](https://en.wikipedia.org/wiki/Decorator_pattern) an existing Bash
function, wrapping it with a caching layer that temporarily retains the output and exit status of
the backing function, in order to speed up repeated calls, at the expense of slightly stale data.

By default the cache is keyed off the function arguments (meaning `foo`, `foo bar`, and `foo baz`
are each cached separately). It's also possible to specify environment variables that should be
included in the cache key - often `PWD` is used to cache functions whose semantics depend on the
current working directory.

Data is generally cached for no more than 60 seconds, and the cache is refreshed in the background
if more than 10 seconds old. In the future these values may be configurable.

#### Suggested Usage

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

#### Calling the original function

If needed, the original function can be invoked via `bc::orig::FUNCTION_NAME` (e.g.
`bc::orig::my_expensive_function`).

### `bc::copy_function`

This helper function copies an existing function to a new name. This can be used to decorate or
replace a function by first copying the function and then defining a new function with the original
name. This is how `bc::cache` overwrites the function being decorated.

If desired you can stop caching a particular function by copying the `bc::orig::...`
function back to its original name:

```shell
bc::copy_function bc::orig::my_expensive_function my_expensive_function
```

### `bc::on` and `bc::off`

Enables or disables caching shell-wide. If `bc::off` is called all cached functions will delegate
immediately to the original function they decorate and will not attempt to use cached data or
cache new data. Call `bc::on` to re-enable caching.

## Copyright and License

Copyright 2012-2017 Michael Diamond

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
