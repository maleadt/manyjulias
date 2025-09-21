# manyjulias

This repository provides scripts and tools to use
[elfshaker](https://github.com/elfshaker/elfshaker) with Julia for the purpose
of storing many builds of Julia and being able to quickly launch any of them.

## Pre-requisites

You will need to have a copy of Julia locally.

You don't need to have elfshaker installed, as manyjulia will download and use elfshaker_jll.

## Quick start

Check out this repository, and generate a couple of Julia builds for the current
development version:

```
$ cd manyjulias
$ julia --project bin/build.jl
```

This will take a long time, and you can interrupt the process at any point.
Then, you can quickly launch any of the completed builds by their Git revision:

```
$ cd manyjulias
$ julia --project bin/julia.jl GIT_REV
```


## Installation

By default, manyjulias will store and retrieve builds from a directory in your
scratch space. If you want the built binaries to be available to other users,
it's recommended to store them in a publicly-readable directory instead:

```
$ cd manyjulias
$ julia --project

julia> using manyjulias
julia> manyjulias.set_data_dir("/public/manyjulias")
```

This will write a `LocalPreferences.toml` file in the `manyjulias` folder. To
have that be picked up by other users, you can deploy a simple script with
absolute paths to the Julia interpreter and your `manyjulias` check-out:

```bash
#!/bin/bash

/path/to/julia --project=/path/to/manyjulias /path/to/manyjulias/bin/julia.jl "$@"
```

With this set-up, other users can simply use the `manyjulias` script instead of
a regular `julia` invocation, with the only difference that the first argument
is the Git revision of the Julia version.


## Bisecting with manyjulias

The main use case for manyjulias is to simplify bisecting scripts. You can do so
manually by testing each revision and typing `git bisect good`, `bad` or `skip`,
but it's also possible to write a script that does this for you:

`bisect.sh`
```bash
#!/bin/bash

if [ $# -ge 1 ]; then
    rev=$1
else
    rev=$(git rev-parse HEAD)
fi

log=$(mktemp --suffix=.log)
trap 'rm -f $log' EXIT

manyjulias $rev bisect.jl |& tee -a $log
exitcode=$?

# preserve code=125: this indicates a missing build, which git should skip
[[ $exitcode == 125 ]] && exit 125

# check whatever you want here, either based on the exit code or log
grep -A1 "Internal error" $log && exit 1

exit 0
```

`bisect.jl`
```julia
# do whatever you want to bisect here, e.g., testing a package that broke

using Pkg
Pkg.activate(; temp=true)

package = "MyBrokenPackage"

withenv("JULIA_PKG_PRECOMPILE_AUTO" => false) do
    Pkg.add(package)
end
Pkg.test(package)
```

With these scripts in place, start by figuring out the initial `good` and `bad`
commits. You can easily do so by invoking `bisect.sh` with a Git revision:

```
$ cd julia

$ ./bisect.sh master
$ echo $?
1
# the master branch is bad

$ ./bisect.sh master~100
$ echo $?
0
# we found a good commit
```

What remains is to inform Git about this and kick off a non-interactive bisect:

```
$ git bisect bad master
$ git bisect good master~100
$ git bisect run ./bisect.sh
```


## Limitations

We use elfshaker to store a database of Julia builds. This tool was designed to
compactly store many LLVM builds, and has achieved impressive compression ratios
(up to 4000x). Sadly, because of how Julia is build, we do not get the same
ratios (only about 20x), making it impossible to host these packs.

## Example database sizes

| Julia release      | Size |
| ------------------ | ---- |
| julia-1.7          | 55G  |
| julia-1.8          | 56G  |
| julia-1.9          | 117G |
| julia-1.9-asserts  | 115G |
| julia-1.10         | 121G |
| julia-1.10-asserts | 121G |
| julia-1.11         | 159G |
| julia-1.11-asserts | 159G |
| julia-1.12         | 286G |
| julia-1.12-asserts | 286G |
