#!/usr/bin/env bash
# Source this file from Bash on the OpenBMC build host.

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

    "$venv/bin/python" -m pip install "meson${version}" requests || return 1
    "$venv/bin/meson" --version
}

# Usage: bmcweb_test [MACHINE [TEST_EXECUTABLE [GTEST_FILTER]]]
# Omitted arguments are prompted for. An empty filter runs the whole executable.
bmcweb_test() (
    local machine="${1:-}"
    local target="${2:-}"
    local filter="${3:-}"
    local venv="${BMCWEB_TEST_VENV:-$HOME/.venvs/bmcweb-host-tests}"

    if (( $# > 3 )); then
        echo 'Usage: bmcweb_test [MACHINE [TEST_EXECUTABLE [GTEST_FILTER]]]' >&2
        return 2
    fi
    if [[ -z "$machine" ]]; then
        read -r -p 'OpenBMC machine: ' machine || return 1
    fi
    if [[ -z "$target" ]]; then
        read -r -p 'Test executable (e.g. registries_test): ' target || return 1
    fi
    if [[ -z "$machine" || -z "$target" ]]; then
        echo 'Machine and test executable are required.' >&2
        return 2
    fi
    if (( $# < 3 )); then
        read -r -p 'Google Test filter (Enter for all tests): ' filter || return 1
    fi

    local root="${OPENBMC_ROOT:-$HOME/Projects/openbmc_aspeed_sdk_11.03/openbmc-11.03}"
    local src="$root/build/$machine/workspace/sources/bmcweb"
    local build="$src/build-host-tests"

    if [[ ! -f "$src/meson.build" ]]; then
        printf 'Cannot find the bmcweb checkout at %s\n' "$src" >&2
        return 1
    fi

    if [[ ! -x "$venv/bin/meson" ]] ||
       ! "$venv/bin/python" -c 'import requests' 2>/dev/null; then
        bmcweb_test_env || return 1
    fi

    # Read the selected machine's registry inputs before changing host tools.
    local registry_files
    registry_files=$(
        set -o pipefail
        cd "$root" || exit 1
        source ./setup "$machine" >&2 || exit 1
        bitbake -e bmcweb |
            sed -n '/^EXTRA_OEMESON="/s/.*-Dpdi-registry-files=\([^"[:space:]]*\).*/\1/p'
    ) || return 1

    if [[ -z "$registry_files" ]]; then
        printf 'No pdi-registry-files setting found for %s.\n' "$machine" >&2
        return 1
    fi

    export PATH="$venv/bin:$PATH"

    _bmcweb_select_gcc "$src" || return 1
    if [[ -n "${CXX:-}" ]]; then
        local version
        version=$("$CXX" -dumpfullversion -dumpversion) || return 1
        build="$src/build-host-tests-${CXX##*/}-$version"
    fi

    local -a setup_args=()
    if [[ -f "$build/meson-private/coredata.dat" ]]; then
        setup_args+=(--reconfigure)
    fi

    "$venv/bin/meson" setup "${setup_args[@]}" "$build" "$src" \
        -Dtests=enabled \
        -Dredfish-dbus-log=enabled \
        "-Dpdi-registry-files=$registry_files" || return 1

    ninja -C "$build" "test/$target" || return 1
    "$build/test/$target" --gtest_filter="${filter:-*}"
)
