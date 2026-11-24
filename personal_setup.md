# Personal setup

## Personal shell setup in one paste

Copy the whole block for your shell into the indicated startup file. If you previously installed these helpers, update their definitions in place. Open a new terminal to load it.

Run `tools_help` whenever you need a reminder of the available commands. Run `check_python path/to/file.py` to check Python syntax without running the file.

### macOS — `~/.zshrc`

```zsh
BMC_SCRIPTS_DIR="$HOME/Desktop/scripts"

validate_redfish() { bash "$BMC_SCRIPTS_DIR/validate-redfish.sh" "$@"; }
generate_openapi() { python3 "$BMC_SCRIPTS_DIR/generate-openapi.py" "$@"; }

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
        'validate_redfish --help   Validate all Redfish resources or one URI.' \
        'generate_openapi --watch  Refresh openapi.yaml after route edits.' \
        'tools_help          List personal shell commands.'
}
```

Reload with `source ~/.zshrc`.

### Linux / Windows Bash — `~/.bashrc`

Copy the following block into the personal settings section of `~/.bashrc`. Keep any other company or personal settings in that file. This block includes the company Git branch prompt and the OpenBMC helpers.

```bash
# ── Personal settings ────────────────────────────────────────────────────────

OPENBMC_ROOT="${OPENBMC_ROOT:-$HOME/Projects/openbmc_aspeed_sdk_11.03/openbmc-11.03}"
BMC_SCRIPTS_DIR="$HOME/Desktop/scripts"

validate_redfish() { bash "$BMC_SCRIPTS_DIR/validate-redfish.sh" "$@"; }
generate_openapi() { python3 "$BMC_SCRIPTS_DIR/generate-openapi.py" "$@"; }

if [[ $- == *i* ]]; then
    bind 'set enable-bracketed-paste on'
    if ! declare -F __git_ps1 >/dev/null; then
        for git_prompt_file in /usr/lib/git-core/git-sh-prompt /usr/share/git/completion/git-prompt.sh /etc/bash_completion.d/git-prompt; do
            if [[ -r "$git_prompt_file" ]]; then
                source "$git_prompt_file"
                if declare -F __git_ps1 >/dev/null; then break; fi
            fi
        done
        unset git_prompt_file
    fi
    if declare -F __git_ps1 >/dev/null; then
        shopt -s promptvars
        # Keep the parentheses in the terminal's default color.
        git_branch_format=$' (\001\e[33m\002%s\001\e[0m\002)'
        PS1='\[\033[32m\]\u@\h\[\033[00m\]:\[\033[34m\]\w\[\033[00m\]$(__git_ps1 "$git_branch_format")\$ '
    fi
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

alias bmcweb_f5='python3 "$BMC_SCRIPTS_DIR/setup_vscode.py" --bmcweb-debug'

# Load the bmcweb host-test helpers from the personal scripts directory.
source "${BMCWEB_TEST_SCRIPT:-$BMC_SCRIPTS_DIR/bmcweb_tests.sh}"

# ── OpenBMC QEMU ─────────────────────────────────────────────────────────────

bmc_qemu() {
    local launcher="${BMC_QEMU_SCRIPT:-$BMC_SCRIPTS_DIR/start_qemu.sh}"
    if [[ ! -r "$launcher" ]]; then
        printf 'Cannot read QEMU launcher: %s\n' "$launcher" >&2
        return 1
    fi

    OPENBMC_ROOT="$OPENBMC_ROOT" bash "$launcher" "$@"
}

# ── Help ─────────────────────────────────────────────────────────────────────

tools_help() {
    cat <<'HELP'
check_python FILE                       Check Python syntax.
check_json FILE                         Check JSON syntax.
git_where                               Show repository, branch, and changes.
patch_check PATCH                       Check whether a Git patch applies.

bmcweb_test_env [VERSION_SPEC]          Set up Meson and requests.
bmcweb_test [MACHINE [TARGET [FILTER]]] Incrementally build and run a host test.
  bmcweb_test cm14ep3r                              Choose from all targets shown side by side.
  bmcweb_test cm14ep3r event_log_test               Run all cases in event_log_test.
  bmcweb_test cm14ep3r registries_test 'DbusEventMapping.*'   Run only matching cases.
bmcweb_test --setup [MACHINE [TARGET [FILTER]]] Prepare the machine build and run the test.
bmcweb_test --gdb [MACHINE [TARGET [FILTER]]]   Open the selected test in GDB.
                                        Omitted arguments are prompted for.
BMCWEB_GCC_ROOT=/path bmcweb_test --setup ...   Use a specific host GCC toolchain.
bmcweb_f5 [--test-target TARGET]        Pick a host test or add TARGET to the VS Code F5 menu.

To debug a bmcweb host test in VS Code:
  1. From workspace/sources, run bmcweb_f5 and choose a test executable by number.
  2. Open its C++ test file and click beside a line number to set a breakpoint.
  3. In Run and Debug, select "Debug bmcweb host test (<your target>)" and press F5.
     Enter a Google Test filter, or accept * for all cases in that executable.
  4. To rerun the same binary, choose "Debug last build (<your target>)".
     After editing C++ code, use the build-and-debug entry again.

validate_redfish --help            Validate the service tree, one URI, or a subtree.
generate_openapi [--watch]         Generate openapi.yaml from bmcweb routes.
                                        Use workspace/sources as the working directory for the default paths.

bmc_qemu                                Prompt for an OpenBMC machine.
bmc_qemu MACHINE [OPTIONS]              Start QEMU for that machine.
bmc_qemu --help                         Show all launcher options.
HELP
}
```

Reload with `source ~/.bashrc`. On Windows, use this in WSL or Git Bash; PowerShell uses a different configuration.

### Validate Redfish and inspect route changes

Store both scripts in `$BMC_SCRIPTS_DIR` with the other helpers. Run these examples from the machine’s `workspace/sources` so the relative paths `bmcweb/`, `openapi.yaml`, `config.ini`, and `logs/` resolve there. For
validation, create a private `config.ini` (mode 600) with the running BMC or
QEMU HTTPS address and credentials. For example:

```ini
[Connection]
rhost = https://localhost:2443
[Authentication]
authtype = Session
user = YOUR_USER
password = YOUR_PASSWORD
```

```bash
validate_redfish --install
validate_redfish --config config.ini
validate_redfish --config config.ini --payload Single /redfish/v1/Systems/system/LogServices/EventLog
validate_redfish --config config.ini --payload Tree /redfish/v1/Systems/system/LogServices/EventLog
```

The default run traverses the service root and writes reports under `./logs`.
The validator defaults to sampling up to 20 LogEntry members. Use
`--collectionlimit LogEntry COUNT` to change that limit. Deploy your changed
bmcweb build before validating its responses.

For a source preview, run `generate_openapi` once or
`generate_openapi --watch` to refresh `openapi.yaml` after saves.
The generator requires Python 3 and PyYAML. Use `--source PATH` for another
bmcweb checkout and `-o FILE` to choose the output path. The YAML lists paths
and methods from literal Redfish v1 route declarations, including conditional
features. Handler response fields, runtime route availability and OEM routes
registered dynamically are outside its scope.

### Run bmcweb host tests

Place `bmcweb_tests.sh` and `start_qemu.sh` in the directory set by `BMC_SCRIPTS_DIR` on the Linux build host. To move the scripts, edit that one setting in `~/.bashrc`. To override only the test script, set
`BMCWEB_TEST_SCRIPT` to its path before loading the Bash block. A full run uses BitBake’s patched sdbusplus source for the selected machine and stages the native build under `build/MACHINE/bmcweb-host-tests` using rsync. The initial `--setup` run prepares Meson and requests.
For a recognized GCC minimum, it checks installed compilers and then uses npm
and npx to install a matching xPack GCC in the user store if necessary.
Set `BMCWEB_GCC_ROOT` to select an existing toolchain explicitly.

On the company Ubuntu host, the first run downloads missing PAM and systemd
development/runtime packages into `~/tools/bmcweb-host-deps` (override with
`BMCWEB_HOST_DEPS`). The helper prepares requests, Mako, MarkupSafe and
inflection in the test venv. It uses the checkout's nlohmann JSON wrap and
builds the nghttp2 library from its Meson wrap when the private
prefix lacks a compatible library. These steps require access to the configured
package and source mirrors on the first run. SDK native pkgconf and CMake are
selected from the current machine's recipe when available; `BMCWEB_NATIVE_BIN`
overrides their directory.

```bash
bmcweb_test --setup cm14ep3r registries_test 'DbusEventMapping.*'
```

After the first full setup for a machine, use the default command for edits to bmcweb
and its tests. It syncs the checkout, reuses the staged subprojects and host
environment, and runs an incremental Ninja build before executing the test.

```bash
bmcweb_test cm14ep3r registries_test 'DbusEventMapping.*'
```

Run with `--setup` after changing SDK recipes, registry inputs outside the
checkout, anything under `subprojects/`, or host tools and dependencies.

To debug a test on the build host, start GDB and set a source breakpoint
before running the selected test. This requires GDB on the host and debug
symbols for source-level inspection.

```bash
bmcweb_test --gdb cm14ep3r registries_test 'DbusEventMapping.UnmappedLiteonEventKeepsMessageAndGetsCompanyMessageId'
```

```gdb
break registries_test.cpp:56
run
print event
step
```

### Pick and run a bmcweb host test in Bash

```bash
source ~/Desktop/scripts/bmcweb_tests.sh
bmcweb_test cm14ep3r
```

Enter a test number to build and immediately run all cases in that executable.
Enter **0** or press **Enter** for the whole suite, or enter **q** to cancel.
With just `bmcweb_test`, first select a machine by number or name. The menu
lists SDK build directories containing `workspace/sources/bmcweb/meson.build`.
Set `OPENBMC_ROOT` to select a different SDK. For an individual
case, pass the executable and Google Test filter explicitly. With
`bmcweb_test --gdb cm14ep3r`, select an individual executable to load in GDB.

### Debug a bmcweb host test with VS Code F5

On the Linux build host, install GDB and enable Microsoft's C/C++ extension
in the remote VS Code window. From the selected machine's
`build/<machine>/workspace/sources` directory, run:

```bash
python3 ~/personal-setup/setup_vscode.py --bmcweb-debug
code devtool-sources.code-workspace
```

This configures debugging in the workspace file outside the bmcweb checkout.
The generator finds `bmcweb_tests.sh` beside itself. To use another copy,
set `BMCWEB_TEST_SCRIPT` when running the generator. The normal multi-root
setup also generates the debug configuration.

The first F5 entry, **Run all bmcweb host tests**, builds and runs the tests
registered by the bmcweb Meson project for this machine. In an existing
workspace, select it once if VS Code remembers an earlier launch selection.
Results and failures appear in the terminal. To run the same suite in Bash:

```bash
source ~/Desktop/scripts/bmcweb_tests.sh
bmcweb_test --all cm14ep3r
```

For C++ breakpoints, use the individual executable configuration.
Open the test in the **bmcweb** folder, click the gutter at an executable
line, select **Debug bmcweb host test (<target>)** for the executable you chose in Run and Debug,
and press **F5**. Enter a Google Test filter such as `DbusEventMapping.*`,
or accept `*` to run the whole executable. The build task prepares a fresh
machine on first use, syncs edits and builds with Ninja. VS Code then starts
GDB with the host runtime environment and maps the staged sources back to
the checkout. After the first successful F5 build, select **Debug last build (<target>)**
to rerun the executable with VS Code breakpoints and a new filter.
It skips source sync and compilation. After editing code, select the original
build-and-debug configuration to refresh the binary and its line information. After SDK or dependency
changes, refresh with `bmcweb_test --setup` as described above.

For another machine, run the two commands from its own `workspace/sources`.
To add a different test executable to the F5 dropdown, rerun the generator
with `--bmcweb-debug --test-target <executable>`. Terminal debugging with
`bmcweb_test --gdb` is also available.

#### Bash shortcut and additional test files

The Bash block above defines `bmcweb_f5` for scripts in `~/Desktop/scripts`. From the selected machine's
`workspace/sources` or `workspace/sources/bmcweb`, run:

```bash
bmcweb_f5
bmcweb_f5 --test-target event_log_test
```

In an interactive terminal, the first command lists the current machine's
registered bmcweb test executables side by side, wrapping to the terminal width. Enter a number to add that
target to the F5 dropdown, **Enter** or **0** for the standard whole-suite
configuration, or **q** to leave the workspace file untouched. The picker
refreshes the Meson test list after syncing local changes. On a fresh
machine, the first invocation prepares the host-test environment.
An explicit target, a dry run, or noninteractive use skips the prompt.

The second command adds build-and-debug and last-build F5 entries for
`event_log_test` alongside the existing entries. Use the test executable
name from your checkout. For example, when `test/meson.build` creates each
executable with `fs.stem(test_src)`, `event_log_test.cpp` builds as
`event_log_test`. To debug it, select **Debug bmcweb host test (event_log_test)**.

For a new standalone test file, follow the checkout's test registration
pattern. In the layout above, add its path relative to `test/` to the
unit-test source list in `test/meson.build`. The next **Run all bmcweb host
tests** includes the registered executable automatically. New Google Test
cases added to an existing registered file run with that executable's
`*` filter after rebuilding.

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
