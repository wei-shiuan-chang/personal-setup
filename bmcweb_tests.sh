#!/usr/bin/env bash
# Source this file from Bash on the OpenBMC build host.

# Host environment setup

_bmcweb_select_gcc() {
    local src="$1"
    local required compiler version prefix name
    local store="${XPACKS_REPO_FOLDER:-$HOME/.local/xPacks}/@xpack-dev-tools/gcc"

    # Read the version guard immediately before bmcweb's GCC error message.
    required=$(python3 - "$src/meson.build" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(
    r"""version_compare\(\s*['"]<\s*([\d.]+)['"]\s*\)\s*\)\s*"""
    r"""error\(\s*['"]This project requires gcc-""",
    text,
    re.IGNORECASE,
)
if match:
    print(match.group(1))
PY
    ) || return 1

    if [[ -n "${BMCWEB_GCC_ROOT:-}" ]]; then
        # An explicit override takes priority.
        compiler="$BMCWEB_GCC_ROOT/bin/g++"
        [[ -x "$compiler" ]] || {
            printf 'Compiler not found: %s\n' "$compiler" >&2
            return 1
        }
    elif [[ -z "$required" ]]; then
        # Let Meson choose when this checkout has no recognized GCC guard.
        return 0
    else
        local -a candidates=()
        local system_gxx
        system_gxx=$(command -v g++) && candidates+=("$system_gxx")
        candidates+=(/usr/bin/g++-[0-9]*)
        candidates+=("$HOME"/tools/xpack-gcc-*/bin/g++)
        candidates+=("$store"/*/.content/bin/g++)

        compiler=""
        for name in "${candidates[@]}"; do
            [[ -x "$name" ]] || continue
            version=$("$name" -dumpfullversion -dumpversion) || continue
            if dpkg --compare-versions "$version" ge "$required"; then
                compiler="$name"
                break
            fi
        done

        if [[ -z "$compiler" ]]; then
            # npm selects an official xPack release in the required GCC major.
            command -v npm >/dev/null && command -v npx >/dev/null || {
                echo 'Automatic GCC download requires npm and npx on this host.' >&2
                return 1
            }

            local release
            release=$(
                set -o pipefail
                npm view @xpack-dev-tools/gcc versions --json |
                    python3 -c '
import json, re, sys
minimum = tuple(map(int, sys.argv[1].split(".")))
minimum = (minimum + (0, 0))[:3]
matches = []
for tag in json.load(sys.stdin):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)-(\d+(?:\.\d+)*)", tag)
    if m:
        gcc = tuple(map(int, m.groups()[:3]))
        if gcc[0] == minimum[0] and gcc >= minimum:
            matches.append((gcc, tuple(map(int, m[4].split("."))), tag))
if not matches:
    sys.exit("No matching xPack GCC release found")
print(max(matches)[2])
' "$required"
            ) || return 1

            printf 'Project requires GCC >= %s. Installing xPack GCC %s for this user.\n' \
                "$required" "$release" >&2
            npx --yes --package=xpm -- xpm install \
                "@xpack-dev-tools/gcc@$release" --global || return 1
            compiler="$store/$release/.content/bin/g++"
        fi
    fi

    version=$("$compiler" -dumpfullversion -dumpversion) || return 1
    if [[ -n "$required" ]] && ! dpkg --compare-versions "$version" ge "$required"; then
        printf 'Selected GCC %s, but this checkout requires >= %s.\n' \
            "$version" "$required" >&2
        return 1
    fi

    prefix="${compiler%/bin/*}"
    name="${compiler##*/}"
    export CXX="$compiler"
    export CC="${compiler%/*}/${name/g++/gcc}"
    [[ -x "$CC" ]] || { printf 'Compiler not found: %s\n' "$CC" >&2; return 1; }

    if [[ "$prefix" != /usr && -d "$prefix/lib64" ]]; then
        export LD_LIBRARY_PATH="$prefix/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    printf 'Using %s (GCC %s)\n' "$CXX" "$version"
}

bmcweb_test_env() {
    local version="${1:-${BMCWEB_MESON_VERSION:->=1.3,<2}}"
    local venv="${BMCWEB_TEST_VENV:-$HOME/.venvs/bmcweb-host-tests}"

    if [[ ! -x "$venv/bin/python" ]]; then
        python3 -m venv "$venv" || return 1
    fi

    "$venv/bin/python" -m pip install "meson${version}" requests inflection Mako MarkupSafe PyYAML 'jsonschema>=4' || return 1
    "$venv/bin/meson" --version
}

# Prepare the private Debian/Ubuntu host prefix before configuring Meson.
_bmcweb_prepare_libs() (
    local deps=$1 lib=$2 src=$3 venv=$4
    local cache
    mkdir -p "$deps" || return 1
    exec 9>"$deps/.bmcweb-prepare.lock" || return 1
    flock 9 || return 1
    cache=$(mktemp -d) || return 1
    trap 'rm -rf -- "$cache"' EXIT

    local -a packages=()
    if [[ ! -r "$deps/usr/include/security/pam_appl.h" || ! -r "$lib/libpam.so" ]]; then
        packages+=(libpam0g-dev libpam0g)
    fi
    if [[ ! -r "$deps/usr/include/systemd/sd-bus.h" || ! -r "$lib/libsystemd.so" ||
          ! -r "$lib/pkgconfig/libsystemd.pc" ]]; then
        packages+=(libsystemd-dev libsystemd0)
    fi
    if ! command -v "$PKG_CONFIG" >/dev/null && [[ ! -x "$deps/usr/bin/pkgconf" ]]; then
        packages+=(pkgconf)
        # Debian splits the binary and its runtime differently across releases.
        local pkg
        for pkg in pkgconf-bin libpkgconf3 libpkgconf7; do
            if apt-cache show "$pkg" 2>/dev/null | grep '^Package:' >/dev/null; then
                packages+=("$pkg")
            fi
        done
    fi
    if (( ${#packages[@]} )); then
        (cd "$cache" && apt-get download "${packages[@]}") || return 1
        local deb
        for deb in "$cache"/*.deb; do
            dpkg-deb -x "$deb" "$deps" || return 1
        done
    fi
    # Some Ubuntu runtime packages install under /lib rather than /usr/lib.
    local runtime base
    for base in libpam libsystemd; do
        if [[ ! -r "$lib/$base.so" ]]; then
            for runtime in "$lib/$base.so.0" "$deps/lib/${lib##*/}/$base.so.0"; do
                if [[ -r "$runtime" ]]; then
                    ln -sfn "$runtime" "$lib/$base.so" || return 1
                    break
                fi
            done
        fi
        [[ -r "$lib/$base.so" ]] || { echo "Missing host library: $lib/$base.so" >&2; return 1; }
    done

    if ! command -v "$PKG_CONFIG" >/dev/null; then
        export PKG_CONFIG="$deps/usr/bin/pkgconf"
    fi
    "$PKG_CONFIG" --version >/dev/null || return 1

    local wrap="$src/subprojects/nghttp2.wrap" directory required ngsrc
    if [[ -f "$wrap" ]]; then
        directory=$(sed -nE 's/^directory[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$wrap")
        ngsrc="$src/subprojects/${directory:-nghttp2}"
        required=$(sed -nE 's/^revision[[:space:]]*=[[:space:]]*v?([0-9]+(\.[0-9]+)+)[[:space:]]*$/\1/p' "$wrap")
        if [[ -z "$required" && "$directory" =~ ^nghttp2-([0-9]+(\.[0-9]+)+)$ ]]; then
            required=${BASH_REMATCH[1]}
        fi
        if ! "$PKG_CONFIG" --atleast-version="${required:-0}" libnghttp2 ||
           [[ ! -r "$deps/usr/include/nghttp2/nghttp2.h" ]] ||
           [[ ! -r "$lib/libnghttp2.a" && ! -r "$lib/libnghttp2.so" ]]; then
            if [[ ! -r "$ngsrc/CMakeLists.txt" ]]; then
                # Older bmcweb wraps omit method=cmake. Meson then checks
                # for meson.build after fetching and patching the CMake tree.
                local download_log="$cache/nghttp2-download.log"
                if ! (set -o pipefail
                      cd "$src" && "$venv/bin/meson" subprojects download nghttp2 2>&1 |
                          tee "$download_log"); then
                    [[ -s "$ngsrc/CMakeLists.txt" ]] &&
                        grep -Fq 'Subproject exists but has no meson.build file' "$download_log" ||
                        return 1
                fi
            fi
            "$CMAKE" -S "$ngsrc" -B "$cache/build" -G Ninja \
                -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
                "-DCMAKE_INSTALL_LIBDIR=lib/${lib##*/}" -DENABLE_LIB_ONLY=ON \
                -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF || return 1
            "$CMAKE" --build "$cache/build" || return 1
            DESTDIR="$deps" "$CMAKE" --install "$cache/build" || return 1
        fi
    fi
)

# Called inside the bmcweb_test subshell. Adds host flags to setup_args.
_bmcweb_prepare_host() {
    if [[ ! -x "$venv/bin/meson" ]] ||
       ! "$venv/bin/python" -c 'import requests, inflection, mako, markupsafe, yaml; from jsonschema import Draft202012Validator' 2>/dev/null; then
        bmcweb_test_env || return 1
    fi

    export PATH="$venv/bin:$PATH"

    _bmcweb_select_gcc "$src" || return 1
    if [[ -n "${CXX:-}" ]]; then
        local version
        version=$("$CXX" -dumpfullversion -dumpversion) || return 1
        build+="-${CXX##*/}-$version"
    fi

    local deps="${BMCWEB_HOST_DEPS:-$HOME/tools/bmcweb-host-deps}"
    local triplet lib inc json native_bin
    triplet=$(dpkg-architecture -qDEB_HOST_MULTIARCH) || return 1
    lib="$deps/usr/lib/$triplet"
    inc="$deps/usr/include"
    native_bin="${BMCWEB_NATIVE_BIN:-${native_root:+$native_root/usr/bin}}"

    export PKG_CONFIG_SYSROOT_DIR="$deps"
    export PKG_CONFIG_LIBDIR="$lib/pkgconfig:$deps/usr/share/pkgconfig:/usr/share/pkgconfig"
    export PKG_CONFIG_PATH=
    if [[ -n "$native_bin" && -x "$native_bin/pkgconf" ]]; then
        export PKG_CONFIG="$native_bin/pkgconf"
    else
        export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
    fi
    if [[ -n "$native_bin" && -x "$native_bin/cmake" ]]; then
        export CMAKE="$native_bin/cmake"
    else
        export CMAKE="${CMAKE:-cmake}"
    fi
    if ! command -v "$CMAKE" >/dev/null; then
        "$venv/bin/python" -m pip install cmake || return 1
    fi
    if ! command -v ninja >/dev/null; then
        "$venv/bin/python" -m pip install ninja || return 1
    fi
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$lib"
    _bmcweb_prepare_libs "$deps" "$lib" "$src" "$venv" || return 1
    if ! command -v "$PKG_CONFIG" >/dev/null; then
        export PKG_CONFIG="$deps/usr/bin/pkgconf"
    fi
    local cpp_args="-I$inc -Wno-error=pedantic -Wno-error=unused-parameter"
    local json_wrap="$src/subprojects/nlohmann_json.wrap" json_dir
    if [[ -f "$json_wrap" ]]; then
        json_dir=$(sed -nE 's/^directory[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$json_wrap")
        json="$src/subprojects/${json_dir:-nlohmann_json}/include"
        if [[ ! -r "$json/nlohmann/json_fwd.hpp" ]]; then
            (cd "$src" && "$venv/bin/meson" subprojects download nlohmann_json) || return 1
        fi
        [[ -r "$json/nlohmann/json_fwd.hpp" ]] || { echo "Missing json_fwd.hpp under $json" >&2; return 1; }
        cpp_args+=" -I$json"
    fi
    setup_args+=("-Dcpp_args=$cpp_args" "-Dcpp_link_args=-L$lib")
    printf 'Host dependencies: %s\n' "$deps"
    build+="-host-deps"
}

# Machine-specific build and test execution

_bmcweb_sync_checkout() {
    local checkout=$1 stage=$2 exclude=$3
    rsync -a --delete --exclude=.git --exclude='/build*/' --exclude='/oe-*' \
        --exclude="$exclude" "$checkout/" "$stage/"
}

_bmcweb_stage_sources() {
    local checkout=$1 sdk_src=$2 stage=$3
    local directory=sdbusplus wrap="$checkout/subprojects/sdbusplus.wrap"
    if [[ -f "$wrap" ]]; then
        local configured
        configured=$(sed -nE 's/^directory[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$wrap")
        directory=${configured:-sdbusplus}
    fi
    [[ "$directory" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9._-]*$ ]] || return 1
    mkdir -p "$stage/subprojects/$directory" || return 1
    # Mirror local bmcweb edits, leaving the SDK dependency in its own directory.
    _bmcweb_sync_checkout "$checkout" "$stage" "/subprojects/$directory" || return 1
    rsync -rlpc --delete --exclude=.git "$sdk_src/" "$stage/subprojects/$directory/"
}

# Configures the caller's build and host environment for this machine.
_bmcweb_configure() {
    # Read the selected machine's registry inputs before changing host tools.
    local recipe_info registry_files native_root
    recipe_info=$(
        set -o pipefail
        cd "$root" || exit 1
        source ./setup "$machine" >&2 || exit 1
        bitbake -c patch sdbusplus >&2 || exit 1
        bitbake -e sdbusplus | sed -n '/^S="/p' || exit 1
        bitbake -e bmcweb |
            sed -n '/^EXTRA_OEMESON="/p; /^RECIPE_SYSROOT_NATIVE="/p'
    ) || return 1

    registry_files=$(sed -n '/^EXTRA_OEMESON="/s/.*-Dpdi-registry-files=\([^"[:space:]]*\).*/\1/p' <<< "$recipe_info")
    native_root=$(sed -n 's/^RECIPE_SYSROOT_NATIVE="\(.*\)"$/\1/p' <<< "$recipe_info")

    local sdk_src
    sdk_src=$(sed -n 's/^S="\(.*\)"$/\1/p' <<< "$recipe_info")
    if [[ ! -f "$sdk_src/meson.build" || -z "$sdk_src" ]]; then
        printf 'Cannot find the patched sdbusplus source for %s at %s\n' "$machine" "$sdk_src" >&2
        return 1
    fi

    _bmcweb_stage_sources "$src" "$sdk_src" "$work/source" || return 1
    src="$work/source"
    printf 'Using %s sdbusplus from %s\n' "$machine" "$sdk_src"

    local -a setup_args=(--force-fallback-for=sdbusplus)
    if [[ -n "$registry_files" ]]; then
        setup_args+=("-Dpdi-registry-files=$registry_files")
    fi
    _bmcweb_prepare_host || return 1
    if [[ -f "$build/meson-private/coredata.dat" ]]; then
        setup_args+=(--reconfigure)
    fi

    "$venv/bin/meson" setup "${setup_args[@]}" "$build" "$src" \
        -Dtests=enabled \
        -Dredfish-dbus-log=enabled || return 1
}

# Print the numbered choice to stdout so both the terminal and F5 use the same picker.
_bmcweb_pick_target() {
    local build_dir=$1 machine_name=$2 allow_all=$3 names answer i
    local -a targets=()
    names=$(python3 - "$build_dir" <<'PYTHON'
import json
import sys
from pathlib import Path

build = Path(sys.argv[1])
with (build / "meson-info/intro-tests.json").open() as metadata:
    tests = json.load(metadata)
targets = set()
for test in tests:
    if not any(s.split(":", 1)[0] == "bmcweb" for s in test["suite"]):
        continue
    executable = build / test["cmd"][0]
    if executable.parent == build / "test":
        targets.add(executable.name)
for target in sorted(targets):
    print(target)
PYTHON
    ) || return 1
    if [[ -n "$names" ]]; then
        mapfile -t targets <<< "$names"
    elif ! "$allow_all"; then
        echo 'No individual bmcweb host tests found.' >&2
        return 1
    fi
    printf 'Host tests for %s:\n' "$machine_name" >&2
    if "$allow_all"; then
        echo '    0  Run all bmcweb host tests (default)' >&2
    fi
    for i in "${!targets[@]}"; do
        printf '  %3d  %s\n' "$((i + 1))" "${targets[i]}" >&2
    done
    while true; do
        read -r -p 'Select a number (q = cancel): ' answer || return 130
        if [[ "$answer" == [qQ] ]]; then return 130; fi
        if "$allow_all" && [[ -z "$answer" || "$answer" == 0 ]]; then return 0; fi
        for i in "${!targets[@]}"; do
            if [[ "$answer" == "$((i + 1))" ]]; then
                printf '%s\n' "${targets[i]}"
                return 0
            fi
        done
        echo 'Enter one of the listed numbers.' >&2
    done
}

# Usage: bmcweb_test [--setup] [--gdb] [MACHINE [TEST_EXECUTABLE [GTEST_FILTER]]]
#        bmcweb_test [--setup] --all [MACHINE]
# With no target, pick from the machine menu and run all cases in the selection.
bmcweb_test() (
    local setup=false vscode_build=false all=false list_targets=false pick_only=false
    local -a debugger=()
    while (( $# )); do
        case "$1" in
            --setup) setup=true ;;
            --all) all=true ;;
            --vscode-pick) pick_only=true ;;
            --vscode-list) all=true; list_targets=true ;;
            --gdb) debugger=(gdb --args) ;;
            --vscode-build) vscode_build=true ;;
            --fast) ;; # Legacy incremental invocation.
            *) break ;;
        esac
        shift
    done
    local machine="${1:-}"
    local target="${2:-}"
    local filter="${3:-}"
    local venv="${BMCWEB_TEST_VENV:-$HOME/.venvs/bmcweb-host-tests}"

    if (( $# > 3 )); then
        echo 'Usage: bmcweb_test [--setup] [--gdb] [MACHINE [TEST_EXECUTABLE [GTEST_FILTER]]]' >&2
        return 2
    fi
    if [[ -z "$machine" ]]; then
        read -r -p 'OpenBMC machine: ' machine || return 1
    fi
    if "$all"; then
        if (( $# > 1 || ${#debugger[@]} )) || "$vscode_build"; then
            echo 'Usage: bmcweb_test [--setup] --all [MACHINE]' >&2
            return 2
        fi
    fi
    if [[ -z "$machine" ]]; then
        echo 'Machine is required.' >&2
        return 2
    fi
    if [[ -n "$target" ]] && ! "$all" && (( $# < 3 )); then
        read -r -p 'Google Test filter (Enter for all tests): ' filter || return 1
    fi

    local root="${OPENBMC_ROOT:-$HOME/Projects/openbmc_aspeed_sdk_11.03/openbmc-11.03}"
    local src="$root/build/$machine/workspace/sources/bmcweb"
    local work="$root/build/$machine/bmcweb-host-tests"
    local build="$work/build"

    if [[ ! -f "$src/meson.build" ]]; then
        printf 'Cannot find the bmcweb checkout at %s\n' "$src" >&2
        return 1
    fi

    mkdir -p "$work" || return 1
    exec 8>"$work/run.lock" || return 1
    flock 8 || return 1
    local state="$work/fast-build-v1"
    if "$vscode_build" && ! command -v gdb >/dev/null; then
        echo 'Install GDB on the VS Code build host or add it to the task PATH.' >&2
        return 1
    fi
    if { "$vscode_build" || [[ -z "$target" ]]; } && [[ ! -s "$state" ]]; then
        setup=true
    fi
    local -a saved=() env_args=()
    if ! "$setup"; then
        if [[ -s "$state" ]]; then
            mapfile -d '' -t saved < "$state" || return 1
        fi
        if (( ${#saved[@]} < 2 )) || [[ ! -f "${saved[0]}/build.ninja" ||
              ! -f "$work/source/meson.build" ]]; then
            if [[ -z "$target" ]]; then
                printf 'Prepare this machine first: bmcweb_test --setup --all %q\n' "$machine" >&2
                return 1
            fi
            printf 'Prepare this machine first: bmcweb_test --setup %q %q %q\n' "$machine" "$target" "${filter:-*}" >&2
            return 1
        fi
        build=${saved[0]}
        export PATH="${saved[1]}/bin:$PATH"
        env_args=("${saved[@]:2}")
        _bmcweb_sync_checkout "$src" "$work/source" /subprojects || return 1
    else
        # An interrupted setup must not leave the previous build marked ready.
        : > "$state" || return 1
        _bmcweb_configure >&2 || return 1
        local key
        for key in CC CXX CMAKE PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR LD_LIBRARY_PATH; do
            if [[ -v "$key" ]]; then
                env_args+=("$key=${!key}")
            fi
        done
        printf '%s\0' "$build" "$venv" "${env_args[@]}" > "$state.tmp" &&
            mv -- "$state.tmp" "$state" || return 1
    fi

    if "$list_targets" || { ! "$all" && [[ -z "$target" ]]; }; then
        env "${env_args[@]}" ninja -C "$build" build.ninja >&2 || return 1
    fi
    if "$list_targets"; then
        printf '%s\0' "$build"
        cat "$build/meson-info/intro-tests.json"
        return
    fi
    if ! "$all" && [[ -z "$target" ]]; then
        local allow_all=true status
        if (( ${#debugger[@]} )); then allow_all=false; fi
        target=$(_bmcweb_pick_target "$build" "$machine" "$allow_all") || {
            status=$?
            if (( status == 130 )) && ! "$pick_only"; then return 0; fi
            return "$status"
        }
        if "$pick_only"; then
            printf '%s\n' "$target"
            return
        fi
        if [[ -z "$target" ]]; then all=true; fi
    fi
    if "$all"; then
        env "${env_args[@]}" meson test -C "$build" --suite bmcweb --print-errorlogs
        return
    fi
    env "${env_args[@]}" ninja -C "$build" "test/$target" || return 1
    if "$vscode_build"; then
        local launch_dir="$work/vscode/$target"
        mkdir -p "$launch_dir" || return 1
        ln -sfnT "$build/test/$target" "$launch_dir/test" || return 1
        # VS Code starts GDB in a separate process after the build task exits.
        # Preserve the same runtime/toolchain environment as the terminal run.
        (
            umask 077
            printf '#!/usr/bin/env bash\nexec env ' &&
                printf '%q ' "PATH=$PATH" "${env_args[@]}" &&
                printf 'gdb "$@"\n'
        ) > "$launch_dir/gdb.tmp" &&
            chmod 700 "$launch_dir/gdb.tmp" &&
            mv "$launch_dir/gdb.tmp" "$launch_dir/gdb"
        return
    fi
    env "${env_args[@]}" "${debugger[@]}" "$build/test/$target" --gtest_filter="${filter:-*}"
)
