# This script looks for LLVM installations and selects one based on the compatibility with
# available wrappers.
#
# This is somewhat convoluted, as we can find llvm_library in a variety of places using different
# mechanisms, while version matching needs to consider API compatibility.
#
# Environment variables influencing this process:
#   DEBUG=1                     print debug information
#   LLVM_VERSION=$MAJOR.$MINOR  only consider using a specific LLVM version
#                               (which still needs to be compatible)

using Compat
import Compat.String

const DEBUG = haskey(ENV, "DEBUG")

include("common.jl")
include(joinpath(@__DIR__, "..", "src", "logging.jl"))

libname() = return ["libLLVM.so"]

function libname(version::VersionNumber)
    return ["libLLVM-$(version.major).$(version.minor).so",
            "libLLVM-$(version.major).$(version.minor).$(version.patch).so"]
end


#
# Discovery
#

# Discover LLVM installations and their contained libraries, by looking for llvm-config
# binaries in the following order of precedence:
# - shipped llvm-config binaries (first versioned, then unversioned)
# - system-wide llvm-config binaries (first versioned, then unversioned)
#
# NOTE: we only look for llvm-config binaries as we need to compile sources with additional
# API calls. If this isn't necessary anymore, we can also look for plain llvm_library libraries.
# This functionality was present in an early version of this file.

llvms = Vector{Tuple{String, String, VersionNumber}}()

# LLVM versions to look for.
#
# Note that this list can be incomplete, as we'll still look for unversioned llvm-config
# binaries which may yield different versions.
acceptable_versions = [VersionNumber(Base.libllvm_version),
                       v"4.0",
                       v"3.9.0",
                       v"3.8.1", v"3.8.0"]
sort!(acceptable_versions)

if haskey(ENV, "LLVM_VERSION")
    ismatch(r"^\d.\d$", ENV["LLVM_VERSION"]) || error("invalid version requested (should be MAJOR.MINOR)")
    requested_version = Nullable(VersionNumber(ENV["LLVM_VERSION"]))

    # NOTE: even though we'll only consider the requested version,
    #       still look for others as it may be useful for debugging purposes
    push!(acceptable_versions, get(requested_version))
else
    requested_version = Nullable{VersionNumber}()
end

debug("Acceptable LLVM versions: ", join(acceptable_versions, ", "))

# check for llvm-config binaries in known locations
configdirs = [JULIA_HOME, joinpath(JULIA_HOME, "..", "tools"), split(ENV["PATH"], ':')...]
for dir in unique(configdirs)
    isdir(dir) || continue
    debug("Searching for config binaries in $dir")

    # first discover llvm-config binaries
    configs = Vector{Tuple{String, Nullable{VersionNumber}}}()
    for file in readdir(dir), re in [r"llvm-config-(\d).(\d).(\d)", r"llvm-config-(\d).(\d)"]
        m = match(re, file)
        if m != nothing
            path = joinpath(dir, file)
            version = VersionNumber(map(s->parse(Int,s), m.captures)...)
            debug("- found llvm-config at $path")
            push!(configs, tuple(path, Nullable(version)))
        end
    end
    config = joinpath(dir, "llvm-config")
    ispath(config) && push!(configs, tuple(config, Nullable{VersionNumber}()))

    # then discover libraries
    for (config, version) in configs
        debug("Searching for libraries using $config")
        # deal with unversioned llvm-config binaries
        if isnull(version)
            config_version = VersionNumber(readchomp(`$config --version`))
            debug("... reports LLVM v$config_version")
        else
            config_version = get(version)
        end

        # check for libraries
        libdir = readchomp(`$config --libdir`)
        debug("... contains libraries in $libdir")
        for name in [libname(config_version); libname()]
            lib = joinpath(libdir, name)
            if ispath(lib)
                debug("- found v$config_version at $lib")
                push!(llvms, tuple(lib, config, config_version))
            end
        end
    end
end

info("Found $(length(llvms)) LLVM installations, providing $(length(unique(map(t->t[3],llvms)))) different versions")


#
# Selection
#

# First consider installations with a major and minor version matching wrapped headers (see
# the `lib` folder) are considered first. If no such installation have been found, consider
# probably-compatible versions (ie. for which we have an older set of wrapped headers).
#
# If the user requested a specific version, only ever consider that version.

vercmp_match = (a,b) -> a.major==b.major && a.minor==b.minor
vercmp_compat = (a,b) -> a.major>b.major || (a.major==b.major && a.minor>=b.minor)

if !isnull(requested_version)
    info("Overriding selection to match v$(get(requested_version))")
    llvms = filter(t->vercmp_match(t[3],get(requested_version)), llvms)
end

# versions wrapped
wrapped_versions = map(dir->VersionNumber(dir),
                       filter(path->isdir(joinpath(@__DIR__, "..", "lib", path)),
                              readdir(joinpath(@__DIR__, "..", "lib"))))

# select wrapper
matching_llvms = filter(t -> any(v -> vercmp_match(t[3],v), wrapped_versions), llvms)
compatible_llvms = filter(t -> any(v -> vercmp_compat(t[3],v), wrapped_versions), llvms)
if !isempty(matching_llvms)
    (llvm_library, llvm_config, llvm_version) = first(matching_llvms)
    wrapper_version = llvm_version
elseif !isempty(compatible_llvms)
    (llvm_library, llvm_config, llvm_version) = first(compatible_llvms)
    compatible_wrappers = filter(v->vercmp_compat(llvm_version, v), wrapped_versions)
    wrapper_version = last(compatible_wrappers)
    warn("LLVM v$llvm_version is not supported, falling back to support for v$wrapper_version (file an issue if there's incompatibilities)")
else
    error("could not find a compatible LLVM installation")
end

wrapped_libdir = joinpath(@__DIR__, "..", "lib", verstr(wrapper_version))
@assert isdir(wrapped_libdir)


#
# Finishing up
#

llvm_targets = Symbol.(split(readstring(`$llvm_config --targets-built`)))

# build library with extra functions
libllvm_extra = joinpath(@__DIR__, "llvm-extra", "libLLVM_extra.so")
cd(joinpath(@__DIR__, "llvm-extra")) do
    withenv("LLVM_CONFIG" => llvm_config) do
        # force a rebuild as the LLVM installation might have changed, undetectably
        run(`make clean`)
        run(`make -j$(Sys.CPU_CORES+1)`)
    end
end

llvm_library_mtime = stat(llvm_library).mtime

libllvm_wrapper_common = joinpath(wrapped_libdir, "libLLVM_common.jl")
libllvm_wrapper = joinpath(wrapped_libdir, "libLLVM_h.jl")
libllvm_extra_wrapper = joinpath(wrapped_libdir, "..", "libLLVM_extra.jl")

# write ext.jl
open(joinpath(@__DIR__, "ext.jl"), "w") do fh
    write(fh, """
        # library properties
        const lib_version = v"$llvm_version"
        const lib_path = "$llvm_library"
        const lib_mtime = $llvm_library_mtime

        # wrapper properties
        const wrapper_version = v"$wrapper_version"

        # check whether this library is loaded right, if it isn't we have exclusive access
        # allowing destructive operations (like shutting LLVM down).
        # this check doesn't seem to work in __init__
        const exclusive = Libdl.dlopen_e(lib_path, Libdl.RTLD_NOLOAD) == C_NULL

        # installation properties
        const targets = $llvm_targets

        # library loading
        const libllvm = "$libllvm_extra"
        include("$libllvm_wrapper_common")
        include("$libllvm_wrapper")
        include("$libllvm_extra_wrapper")""")
end
