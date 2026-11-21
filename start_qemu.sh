#!/usr/bin/env bash
set -eo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask() {
    read -r -p "$2" "$1" || die "Input required. Use --help for options."
}

root=${OPENBMC_ROOT:-"$HOME/Projects/openbmc_aspeed_sdk_11.03/openbmc-11.03"}
machine= build= native= qemu= bios_dir= rom= image= board= flash= nic= config=
while (($#)); do
    case "$1" in
        -h|--help)
            cat <<'EOF'
Usage: start_qemu.sh [MACHINE | --machine NAME] [options]
  --project-root DIR   SDK checkout (default: OPENBMC_ROOT or company SDK path)
  --build-dir DIR      BitBake build directory
  --config FILE        Full Yocto qemuboot configuration; launch with runqemu
  --image FILE         Use the raw MTD launcher with this flash image
  --native-root DIR    SDK native sysroot containing QEMU and its libraries
  --qemu FILE          QEMU executable
  --qemu-machine NAME  Emulated board
  --bios-dir DIR       QEMU firmware search directory
  --bootrom FILE|none  Boot ROM, or omit -bios
  --fmc-model NAME     FMC flash chip, or "default" for the board default
  --nic NUMBER         Guest NIC for SSH/HTTPS/HTTP forwarding (1-based)

An image-matched qemuboot configuration takes precedence over board defaults.
Explicit raw-launch options select the MTD launcher instead.
EOF
            exit 0 ;;
        --*)
            (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
            case "$1" in
                --machine) machine=$2 ;; --project-root) root=$2 ;;
                --build-dir) build=$2 ;; --config) config=$2 ;;
                --native-root) native=$2 ;; --qemu) qemu=$2 ;;
                --qemu-machine) board=$2 ;; --bios-dir) bios_dir=$2 ;;
                --bootrom) rom=$2 ;; --fmc-model) flash=$2 ;;
                --image) image=$2 ;; --nic) nic=$2 ;;
                *) die "Unknown option: $1" ;;
            esac
            shift 2 ;;
        *) [[ -z $machine ]] || die "Unexpected argument: $1"
           machine=$1; shift ;;
    esac
done
[[ -n $machine ]] || ask machine 'OpenBMC machine: '
[[ -n $machine ]] || die 'Machine is required'
root=$(realpath -e -- "$root") || die 'SDK root not found'
build=$(realpath -e -- "${build:-$root/build/$machine}") || die 'Build directory not found'

# Keep the Yocto environment in a subshell so the raw QEMU process uses host tools.
yocto() (
    cd "$root"
    source ./setup "$machine" "$build" >&2 || exit 1
    "$@"
)
raw_options="$native$qemu$board$bios_dir$rom$flash$image$nic"
if [[ -n $config ]]; then
    [[ -z $raw_options ]] || die '--config and raw-launch options cannot be combined'
    config=$(realpath -e -- "$config") || die 'QEMU configuration not found'
    yocto runqemu "$config" nographic slirp
    exit
fi

env_data=$(yocto bitbake -e obmc-phosphor-image) || die 'Cannot read the image recipe environment'
recipe_var() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" <<< "$env_data"; }
deploy=$(recipe_var DEPLOY_DIR_IMAGE)
tmp=$(recipe_var TMPDIR)
[[ -n $deploy && -n $tmp ]] || die 'Missing DEPLOY_DIR_IMAGE or TMPDIR'
link=$(recipe_var IMAGE_LINK_NAME)
link=${link:-obmc-phosphor-image-$machine}

if [[ -z $raw_options ]]; then
    for config in "$deploy/$link.qemuboot.conf" "$deploy/$link.rootfs.qemuboot.conf"; do
        if [[ -r $config ]]; then
            printf 'Using Yocto QEMU configuration: %s\n' "$config"
            yocto runqemu "$config" nographic slirp
            exit
        fi
    done
fi

native=${native:-$(recipe_var RECIPE_SYSROOT_NATIVE)}
image=${image:-"$deploy/$link.static.mtd"}
if [[ ! -s $image ]]; then
    printf 'Flash image not found: %s\n' "$image" >&2
    ask image 'Full path to raw MTD image: '
fi
[[ -f $image && -s $image && -r $image ]] || die "Invalid image: $image"

if [[ $machine == nvidia-vru ]]; then
    board=${board:-ast2700-evb}
    flash=${flash:-w25q512jv}
    rom=${rom:-ast27x0_bootrom.bin}
    qemu=${qemu:-qemu-system-aarch64}
    nic=${nic:-3}
fi

if [[ -z $qemu ]]; then
    bins=()
    for bin in "$native"/usr/bin/qemu-system-{arm,aarch64}; do
        if [[ -x $bin ]]; then bins+=("$bin"); fi
    done
    if ((${#bins[@]} == 1)); then qemu=${bins[0]}; fi
fi
[[ -n $qemu ]] || ask qemu 'QEMU executable (name or full path): '
if [[ $qemu != */* && -x $native/usr/bin/$qemu ]]; then qemu="$native/usr/bin/$qemu"; fi
qemu=$(command -v -- "$qemu") || die 'QEMU executable not found'
if [[ -n $native && $qemu == "$native/"* && -d $native/usr/lib ]]; then
    export LD_LIBRARY_PATH="$native/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
[[ -n $board ]] || ask board 'QEMU board (name from -machine help): '
"$qemu" -machine help | awk -v b="$board" '$1==b {ok=1} END {exit !ok}' ||
    die "Board unavailable in $qemu: $board"
[[ -n $flash ]] || ask flash 'FMC flash model (Enter for board default): '
[[ -n $rom ]] || ask rom 'Boot ROM path, or "none": '
args=()
if [[ $rom != none ]]; then
    [[ -n $rom ]] || die 'Enter a ROM path or "none"'
    if [[ $rom != /* && ! -f $rom ]]; then
        dirs=()
        if [[ -n $bios_dir ]]; then dirs+=("$bios_dir"); fi
        dirs+=("$native/usr/share/qemu" "$tmp"/sysroots-components/*/qemu-system-native/usr/share/qemu)
        for dir in "${dirs[@]}"; do
            if [[ -f $dir/$rom ]]; then rom="$dir/$rom"; break; fi
        done
    fi
    if [[ ! -s $rom ]]; then ask rom 'ROM not found. Full path to boot ROM: '; fi
    [[ -f $rom && -r $rom && -s $rom ]] || die "Invalid ROM: $rom"
    bios_dir=${bios_dir:-$(dirname -- "$rom")}
    args+=(-bios "$rom")
fi
if [[ -n $bios_dir ]]; then args+=(-L "$bios_dir"); fi
[[ -n $nic ]] || ask nic 'Guest NIC for port forwarding (1 = first NIC): '
[[ $nic =~ ^[1-4]$ ]] || die 'Enter a NIC number from 1 to 4'
model=$board
if [[ -n $flash && $flash != default ]]; then model+=",fmc-model=$flash"; fi
args+=(-machine "$model" -m 2G -nographic -drive "file=$image,if=mtd,format=raw" -serial mon:stdio)
if [[ $machine == nvidia-vru ]]; then args+=(-serial null); fi
for ((i=0; i<nic; i++)); do
    net="user,id=net$i"
    if ((i+1 == nic)); then
        net+=",hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8443-:443,hostfwd=tcp:127.0.0.1:8080-:80"
    fi
    args+=(-netdev "$net" -net "nic,netdev=net$i")
done
printf 'Machine: %s | Board: %s | Flash: %s | ROM: %s\n' "$machine" "$board" "${flash:-default}" "$rom"
printf 'Image: %s\nWebUI: https://127.0.0.1:8443\n' "$(realpath -- "$image")"
exec "$qemu" "${args[@]}"
