# Personal setup

## Personal shell setup in one paste

Copy the whole block for your shell into the indicated startup file. If you already have the prompt or helper there, replace those definitions with the block. Open a new terminal to load it.

Run `tools_help` whenever you need a reminder of the available commands. The prompt shows your current Git branch. Run `check_python path/to/file.py` to check Python syntax without running the file.

### macOS — `~/.zshrc`

```zsh
# Load Zsh's built-in version control helper.
autoload -Uz vcs_info add-zsh-hook
# Refresh Git information before each prompt, including after branch changes.
precmd_vcs_info() { vcs_info }
add-zsh-hook precmd precmd_vcs_info
# Expand the Git information variable each time the prompt is displayed.
setopt prompt_subst
# Display the branch name in cyan, inside parentheses.
zstyle ':vcs_info:git:*' formats '%F{cyan}(%b)%f '
# Green user@host, blue directory, Git branch, then the prompt symbol.
PROMPT='%F{green}%n@%m%f %F{blue}%~%f ${vcs_info_msg_0_}%# '

check_python() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: check_python FILE' >&2
        return 2
    fi
    python3 -c 'import sys; from pathlib import Path; p = Path(sys.argv[1]); compile(p.read_bytes(), str(p), "exec"); print("Syntax OK")' "$1"
}

check_json() {
    python3 -m json.tool "${1:?Usage: check_json FILE}" > /dev/null &&
        printf '%s\n' 'JSON syntax OK'
}

git_where() {
    printf 'Current directory: %s\n' "$PWD"
    git rev-parse --show-toplevel || return
    git status --short --branch
}

patch_check() {
    git apply --check --verbose -- "${1:?Usage: patch_check PATCH}"
}

tools_help() {
    printf '%s\n' \
        'check_python FILE   Check Python syntax without executing it.' \
        'check_json FILE     Check JSON syntax.' \
        'git_where           Show directory, repository, branch and changes.' \
        'patch_check PATCH   Check patch applicability without applying it.' \
        'tools_help          List personal shell commands.'
}
```

Reload with `source ~/.zshrc`.

### Linux / Windows Bash — `~/.bashrc`

For Bash on Linux, WSL, or Git Bash, add the following at the end of `~/.bashrc`, after any existing `PS1` assignment:

```bash
# ── Personal settings ────────────────────────────────────────────────────────

OPENBMC_ROOT="${OPENBMC_ROOT:-$HOME/Projects/openbmc_aspeed_sdk_11.03/openbmc-11.03}"
BMC_QEMU_SCRIPT="${BMC_QEMU_SCRIPT:-$HOME/Desktop/scripts/start_qemu.sh}"
BMCWEB_TEST_VENV="${BMCWEB_TEST_VENV:-$HOME/.venvs/bmcweb-host-tests}"
BMCWEB_MESON_VERSION="${BMCWEB_MESON_VERSION:->=1.3,<2}"

# ── Interactive prompt ───────────────────────────────────────────────────────

parse_git_branch() {
    local branch
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
    printf '(%s) ' "$branch"
}

if [[ $- == *i* ]]; then
    bind 'set enable-bracketed-paste on'
    shopt -s promptvars
    PS1='\[\e[32m\]\u@\h\[\e[0m\] \[\e[34m\]\w\[\e[0m\] \[\e[36m\]$(parse_git_branch)\[\e[0m\]\$ '
fi

# ── File and Git helpers ─────────────────────────────────────────────────────

check_python() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: check_python FILE' >&2
        return 2
    fi

    python3 - "$1" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
compile(path.read_bytes(), str(path), "exec")
print("Syntax OK")
PY
}

check_json() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: check_json FILE' >&2
        return 2
    fi

    python3 -m json.tool "$1" >/dev/null &&
        printf '%s\n' 'JSON syntax OK'
}

git_where() {
    printf 'Current directory: %s\n' "$PWD"
    git rev-parse --show-toplevel || return 1
    git status --short --branch
}

patch_check() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: patch_check PATCH' >&2
        return 2
    fi

    git apply --check --verbose -- "$1"
}

# ── bmcweb host-test environment ─────────────────────────────────────────────

bmcweb_test_env() {
    local version="${1:-$BMCWEB_MESON_VERSION}"
    local venv="$BMCWEB_TEST_VENV"

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
    local venv="$BMCWEB_TEST_VENV"

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

    local src="$OPENBMC_ROOT/build/$machine/workspace/sources/bmcweb"
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
        cd "$OPENBMC_ROOT" || exit 1
        source ./setup "$machine" >&2 || exit 1
        bitbake -e bmcweb |
            sed -n '/^EXTRA_OEMESON="/s/.*-Dpdi-registry-files=\([^"[:space:]]*\).*/\1/p'
    ) || return 1

    if [[ -z "$registry_files" ]]; then
        printf 'No pdi-registry-files setting found for %s.\n' "$machine" >&2
        return 1
    fi

    export PATH="$venv/bin:$PATH"

    # Optional host compiler override. Meson checks the project's requirements.
    if [[ -n "${BMCWEB_GCC_ROOT:-}" ]]; then
        local gcc_root="$BMCWEB_GCC_ROOT"
        local gcc_version

        if [[ ! -x "$gcc_root/bin/gcc" || ! -x "$gcc_root/bin/g++" ]]; then
            printf 'Cannot find gcc and g++ under %s/bin\n' "$gcc_root" >&2
            return 1
        fi

        export CC="$gcc_root/bin/gcc"
        export CXX="$gcc_root/bin/g++"
        export PATH="$gcc_root/bin:$PATH"
        if [[ -d "$gcc_root/lib64" ]]; then
            export LD_LIBRARY_PATH="$gcc_root/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi

        gcc_version=$("$CXX" -dumpfullversion -dumpversion) || return 1
        build="$src/build-host-tests-gcc-$gcc_version"
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

# ── OpenBMC QEMU ─────────────────────────────────────────────────────────────

bmc_qemu() {
    if [[ ! -r "$BMC_QEMU_SCRIPT" ]]; then
        printf 'Cannot read QEMU launcher: %s\n' "$BMC_QEMU_SCRIPT" >&2
        return 1
    fi

    OPENBMC_ROOT="$OPENBMC_ROOT" bash "$BMC_QEMU_SCRIPT" "$@"
}

# ── Help ─────────────────────────────────────────────────────────────────────

tools_help() {
    cat <<'HELP'
check_python FILE                       Check Python syntax.
check_json FILE                         Check JSON syntax.
git_where                               Show repository, branch, and changes.
patch_check PATCH                       Check whether a Git patch applies.

bmcweb_test_env [VERSION_SPEC]          Set up Meson and requests.
bmcweb_test [MACHINE [TARGET [FILTER]]] Build and run a bmcweb host test.
                                        Omitted arguments are prompted for.
BMCWEB_GCC_ROOT=/path bmcweb_test ...   Use a specific host GCC toolchain.

bmc_qemu                                Prompt for an OpenBMC machine.
bmc_qemu MACHINE [OPTIONS]              Start QEMU for that machine.
bmc_qemu --help                         Show all launcher options.
HELP
}
```

Reload with `source ~/.bashrc`. On Windows, use this in WSL or Git Bash; PowerShell uses a different configuration.

Both prompts show `user@host path (branch)` inside a Git repository and omit the branch outside one. The Bash version also omits it when HEAD is detached.

### Run OpenBMC in QEMU

Run these commands on the machine that holds the OpenBMC SDK and build artifacts. For the company SDK, load the helpers on the Linux build host after connecting over SSH. Set `BMC_QEMU_SCRIPT` to the path of your `start_qemu.sh` if it lives elsewhere.

```sh
# Ask for the machine in English.
bmc_qemu

# Use the image from this machine's BitBake DEPLOY_DIR_IMAGE.
bmc_qemu nvidia-vru

# Select a specific image, including one from a different build directory.
bmc_qemu nvidia-vru --image /path/to/firmware.static.mtd
```

## Ubuntu GNOME — Apply a monitor layout at login

1. Press the **Windows/Super** key, search for **Startup Applications**, and open it. You can also press **Alt+F2** and run `gnome-session-properties`.
2. Click **Add**, name the entry **Monitor layout**, and paste your full `xrandr` command into the **Command** field.
3. Save the entry. The command runs each time you log in to your X11 desktop.

[Ubuntu Startup Applications help](https://help.ubuntu.com/stable/ubuntu-help/startup-applications.html.en)

## Ubuntu GNOME — Remap the left modifier keys

Use these steps in the Ubuntu GNOME desktop session. Skip this section in browser mode.

1. Open **Tweaks** and go to **Keyboard & Mouse**.
2. Open **Additional Layout Options**, then expand **Ctrl position**.
3. Check **Left Alt as Ctrl, Left Ctrl as Win, Left Win as Left Alt**.

## Windows — Remap the left modifier keys

| Physical key | Maps to |
| --- | --- |
| Left Win | Left Alt |
| Left Ctrl | Left Win |
| Left Alt | Left Ctrl |

## VS Code

Open the Command Palette with `Cmd+Shift+P` on macOS or `Ctrl+Shift+P` on Windows/Linux.

### User settings

Run **Preferences: Open User Settings (JSON)** and merge the following into your existing settings. The `C_Cpp` options require the Microsoft C/C++ extension.

```jsonc
{
  // Workbench preferences
  "workbench.editor.tabActionLocation": "left",
  "workbench.editor.enablePreview": false,
  "workbench.colorTheme": "Solarized Light",
  "chat.viewSessions.orientation": "stacked",

  // Editor preferences
  "editor.occurrencesHighlight": "multiFile",
  "editor.selectionHighlight": true,
  "editor.inlayHints.enabled": "on",
  "editor.gotoLocation.multipleDefinitions": "goto",
  "editor.minimap.enabled": false,
  "references.preferredLocation": "view",

  // Git history
  "git.blame.editorDecoration.enabled": true,
  "git.blame.statusBarItem.enabled": true,

  // File Watching & Search
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/build/tmp/**": true,
    "**/build/*/tmp/**": true,
    "**/build/sstate-cache/**": true,
    "**/build/*/sstate-cache/**": true,
    "**/build/downloads/**": true,
    "**/build/*/downloads/**": true
  },
  "search.exclude": {
    "**/build/tmp/**": true,
    "**/build/*/tmp/**": true,
    "**/build/sstate-cache/**": true,
    "**/build/*/sstate-cache/**": true,
    "**/build/downloads/**": true,
    "**/build/*/downloads/**": true
  },
  "C_Cpp.files.exclude": {
    "**/build/tmp/": true,
    "**/build/*/tmp/": true,
    "**/build/sstate-cache/": true,
    "**/build/*/sstate-cache/": true,
    "**/build/downloads/": true,
    "**/build/*/downloads/": true,
    "**/oe-workdir/": true,
    "**/oe-logs/": true
  },

  // Optional: C/C++ inlay hints for C/C++ workspaces.
  // Remove these if you only want hints in workspaces that configure them locally.
  "C_Cpp.inlayHints.parameterNames.enabled": true,
  "C_Cpp.inlayHints.referenceOperator.enabled": true,
  "C_Cpp.inlayHints.autoDeclarationTypes.enabled": true,
  "C_Cpp.inlayHints.parameterNames.suppressWhenArgumentContainsName": false,
  "C_Cpp.inlayHints.autoDeclarationTypes.showOnLeft": true,

  // Optional: add parentheses when completing C/C++ functions.
  "C_Cpp.autocompleteAddParentheses": true,

  // Optional: C/C++ indexing performance preferences.
  // Cache size limits disk cache, not RAM. Enable or adjust if needed.
  // "C_Cpp.intelliSenseCacheSize": 512,
  // "C_Cpp.workspaceParsingPriority": "low",
  // "C_Cpp.default.browse.limitSymbolsToIncludedHeaders": true
}
```

### Remote OpenBMC workspace settings

When connected to the remote machine, run **Preferences: Open Workspace Settings (JSON)** and merge these settings into `.vscode/settings.json`. The paths below are an example from the existing Yocto build; update the username, build target, recipe directory, and compiler version to match your build. Generate `compile_commands.json` through the project's build workflow before configuring its path.

```jsonc
{
  // =========================================================
  // File Watching & Search
  // =========================================================
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/build/tmp/**": true,
    "**/build/*/tmp/**": true,
    "**/build/sstate-cache/**": true,
    "**/build/*/sstate-cache/**": true,
    "**/build/downloads/**": true,
    "**/build/*/downloads/**": true
  },

  "search.exclude": {
    "**/build/tmp/**": true,
    "**/build/*/tmp/**": true,
    "**/build/sstate-cache/**": true,
    "**/build/*/sstate-cache/**": true,
    "**/build/downloads/**": true,
    "**/build/*/downloads/**": true
  },

  "C_Cpp.files.exclude": {
    "**/build/tmp/": true,
    "**/build/*/tmp/": true,
    "**/build/sstate-cache/": true,
    "**/build/*/sstate-cache/": true,
    "**/build/downloads/": true,
    "**/build/*/downloads/": true,
    "**/oe-workdir/": true,
    "**/oe-logs/": true
  },

  // =========================================================
  // C/C++ IntelliSense - Yocto Cross Compilation
  // =========================================================
  "C_Cpp.default.compileCommands": "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/bmcweb-1.0+git/compile_commands.json",

  "C_Cpp.default.compilerPath": "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot-native/usr/bin/arm-openbmc-linux-gnueabi/arm-openbmc-linux-gnueabi-g++",

  "C_Cpp.default.intelliSenseMode": "linux-gcc-arm",
  "C_Cpp.default.cppStandard": "c++23",

  "C_Cpp.default.systemIncludePath": [
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot-native/usr/lib/arm-openbmc-linux-gnueabi/gcc/arm-openbmc-linux-gnueabi/16.1.0/include",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot-native/usr/lib/arm-openbmc-linux-gnueabi/gcc/arm-openbmc-linux-gnueabi/16.1.0/include-fixed",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot/usr/include/c++/16.1.0",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot/usr/include/c++/16.1.0/arm-openbmc-linux-gnueabi",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot/usr/include/c++/16.1.0/backward",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot/usr/lib/arm-openbmc-linux-gnueabi/16.1.0/include",
    "/home/vanessa/projects/aspeed/openbmc/build/evb-ast2600/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/bmcweb/1.0+git/recipe-sysroot/usr/include"
  ],

  // =========================================================
  // C/C++ Symbol Navigation
  // =========================================================
  "C_Cpp.default.browse.path": [
    "${workspaceFolder}/redfish-core",
    "${workspaceFolder}/http",
    "${workspaceFolder}/include",
    "${workspaceFolder}/src",
    "${workspaceFolder}/config",
    "${workspaceFolder}/features/google",
    "${workspaceFolder}/features/ibm",
    "${workspaceFolder}/features/kvm",
    "${workspaceFolder}/features/openbmc_rest",
    "${workspaceFolder}/features/serial",
    "${workspaceFolder}/features/virtual_media",
    "${workspaceFolder}/features/webui_login",
    "${workspaceFolder}/test"
  ],

  // =========================================================
  // C/C++ Inlay Hints
  // =========================================================
  "C_Cpp.inlayHints.parameterNames.enabled": true,
  "C_Cpp.inlayHints.referenceOperator.enabled": true,
  "C_Cpp.inlayHints.autoDeclarationTypes.enabled": true,
  "C_Cpp.inlayHints.parameterNames.suppressWhenArgumentContainsName": false,
  "C_Cpp.inlayHints.autoDeclarationTypes.showOnLeft": true,

  // =========================================================
  // C/C++ Autocomplete
  // =========================================================
  "C_Cpp.autocompleteAddParentheses": true,

  // =========================================================
  // Performance Optimization (Optional)
  // =========================================================
  // Previously used to reduce resource consumption when
  // cpptools was indexing large OpenBMC projects.
  //
  // Enable only if performance becomes an issue again.
  //
  // intelliSenseCacheSize: Limits disk cache size, not RAM.
  // workspaceParsingPriority: Lowers background parsing priority.
  // limitSymbolsToIncludedHeaders: Already true by default.
  //
  "C_Cpp.intelliSenseCacheSize": 512,
  "C_Cpp.workspaceParsingPriority": "low",
  "C_Cpp.default.browse.limitSymbolsToIncludedHeaders": true,
}
```


### Keyboard shortcuts

Run **Preferences: Open Keyboard Shortcuts (JSON)** and merge these entries into the existing array. The Windows/Linux bindings below override the usual Shift+arrow text selection shortcuts.

```jsonc
// Place your key bindings in this file to override the defaults
[
  // macOS
  {
    "key": "cmd+down",
    "command": "editor.action.goToDeclaration",
    "when": "isMac && editorTextFocus"
  },
  {
    "key": "cmd+[",
    "command": "workbench.action.navigateBack",
    "when": "isMac"
  },
  {
    "key": "cmd+]",
    "command": "workbench.action.navigateForward",
    "when": "isMac"
  },

  // Linux / Windows
  {
    "key": "ctrl+down",
    "command": "editor.action.goToDeclaration",
    "when": "!isMac && editorTextFocus"
  },
  {
    "key": "shift+down",
    "command": "editor.action.goToDeclaration",
    "when": "!isMac && editorTextFocus"
  },
  {
    "key": "shift+left",
    "command": "workbench.action.navigateBack",
    "when": "!isMac && editorTextFocus"
  },
  {
    "key": "shift+right",
    "command": "workbench.action.navigateForward",
    "when": "!isMac && editorTextFocus"
  }
]
```
