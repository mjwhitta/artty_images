#!/usr/bin/env bash

# shellcheck disable=SC2140

### Helpers begin
check_deps() {
    local missing
    for d in "${deps[@]}"; do
        if [[ -z $(command -v "$d") ]]; then
            # Force absolute path
            if [[ ! -e "/$d" ]]; then
                err "$d was not found"
                missing="true"
            fi
        fi
    done; unset d
    [[ -z $missing ]] || exit 128
}
err() { echo -e "${color:+\e[31m}[!] $*\e[0m"; }
errx() { err "${*:2}"; clean "$1"; }
good() { echo -e "${color:+\e[32m}[+] $*\e[0m"; }
info() { echo -e "${color:+\e[37m}[*] $*\e[0m"; }
long_opt() {
    local arg shift="0"
    case "$1" in
        "--"*"="*) arg="${1#*=}"; [[ -n $arg ]] || return 127 ;;
        *) shift="1"; shift; [[ $# -gt 0 ]] || return 127; arg="$1" ;;
    esac
    echo "$arg"
    return $shift
}
subinfo() { echo -e "${color:+\e[36m}[=] $*\e[0m"; }
warn() { echo -e "${color:+\e[33m}[-] $*\e[0m"; }
### Helpers end

### Parallel helpers begin
set -o noglob
trap "clean 126" SIGINT # Ensure cleanup on ^C
check_lock() {
    [[ -n $cache ]] || errx 125 "Cache is not defined"
    mkdir -p "$cache"
    if [[ -f "$cache.lock" ]]; then
        errx 125 "$cache.lock already exists"
    fi
    echo "$$" >"$cache.lock"
}
check_resume_file() {
    if [[ -f "$json" ]] && [[ -z $resume ]]; then
        warn "Resume file found" >&2
        while :; do
            # Prompt whether to overwrite or resume
            local a
            read -n 1 -p "Would you like to resume [y/n/q/c]: " -rs a
            echo

            case "$a" in
                "c") clean 0 ;;
                "n") write_resume_file; break ;;
                "q") exit 0 ;;
                "y") read_resume_file; resume="--resume"; break ;;
                *) echo "Invalid response, try again!" ;;
            esac
        done
    elif [[ -f "$json" ]]; then
        read_resume_file
    elif [[ -n $resume ]]; then
        errx 124 "No resume file found"
    else
        write_resume_file
    fi
}
clean() {
    if [[ ${1:-0} -eq 0 ]] || [[ ${1:-0} -eq 122 ]]; then
        [[ -z $cache ]] || [[ ! -d "$cache" ]] || rm -rf "$cache"
    fi
    [[ -z $script ]] || [[ ! -f "$script" ]] || rm -f "$script"
    [[ ${1:-0} -eq 125 ]] || [[ -z $cache ]] || rm -f "$cache.lock"
    show_cursor
    exit "${1:-0}"
}
hide_cursor() { echo -en "\e[?25l"; }
json_get() {
    if [[ -z $json ]] || [[ ! -f "$json" ]]; then
        return
    fi
    jq -cr ".$*" "$json" | sed -r "s/^null$//g"
}
show_cursor() { echo -en "\e[?25h"; }
### Parallel helpers end

read_resume_file() { echo -n; }

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS] <image1>... [imageN]

DESCRIPTION
    Add dimensions to image filename.

OPTIONS
    -a, --autocrop       Autocrop images
    -h, --help           Display this help message
    --no-color           Disable colorized output
    -r, --resume         Resume from a previous run
    -s, --size=SIZE      Specify pixel size (default: 1)
    -t, --threads=NUM    Use specified number of threads (default: 32)
    -v, --verbose        Do not hide parallel errors

EOF
    exit "$1"
}

write_resume_file() {
    [[ -n $cache ]] || return
    [[ -n $json ]] || return
    rm -rf "$cache"
    mkdir -p "$cache"
    echo "{}" >"$json"
}

declare -a args
unset autocrop help pixel_size
color="true"
parallel="true"
threads="32"

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift; args+=("$@"); break ;;
        "-a"|"--autocrop") autocrop="true" ;;
        "-h"|"--help") help="true" ;;
        "--no-color") unset color ;;
        "-r"|"--resume") resume="--resume" ;;
        "-s"|"--size"*) pixel_size="$(long_opt "$@")" ;;
        "-t"|"--threads"*) threads="$(long_opt "$@")" ;;
        "-v"|"--verbose") verbose="true" ;;
        *) args+=("$1") ;;
    esac
    case "$?" in
        0) ;;
        1) shift ;;
        *) usage $? ;;
    esac
    shift
done
[[ ${#args[@]} -eq 0 ]] || set -- "${args[@]}"

# Help info
[[ -z $help ]] || usage 0

# Check for missing dependencies
declare -a deps
deps+=("convert")
deps+=("jq")
deps+=("perl")
check_deps

# Check for valid params
[[ $# -gt 0 ]] || [[ -n $resume ]] || usage 1

# Determine parallel situation
if [[ -n $parallel ]] && [[ -z $(command -v parallel) ]]; then
    warn "Parallel is not installed, defaulting to single-threaded"
    unset parallel
fi

# Cite if needed
if [[ -n $parallel ]] && [[ ! -f "$HOME/.parallel/will-cite" ]]; then
    pvers="$(parallel --version | grep -ioPs "parallel \K\d+")"
    if [[ $pvers -gt 20161222 ]] && [[ $pvers -lt 20181122 ]]; then
        mkdir -p "$HOME/.parallel"
        parallel --citation
    fi
    unset pvers
fi

# TODO Save command line args

# Cache variables
hash="$(pwd | sha256sum | awk '{print $1}')"
cache="$HOME/.cache/${0##*/}/$hash"
joblog="$cache/joblog.txt"
json="$cache/${0##*/}.json"

# Lock to prevent parallel issues
check_lock

# Check for resume file
[[ -z $parallel ]] || check_resume_file
hide_cursor

[[ -z $resume ]] || info "Resuming..."

info "Processing dataset for jobs"

dataset="$cache/${0##*/}.dataset"
if [[ ! -f "$dataset" ]]; then
    touch "$dataset"

    for data in "$@"; do
        echo "$data" >>"$dataset"
    done; unset data
fi
total="$(wc -l "$dataset" | awk '{print $1}')"
[[ $total -gt 0 ]] || errx 122 "No dataset provided"

subinfo "$total jobs to run"

# Create sub-script
script="/tmp/${0##*/}.parallel"
cat >"$script" <<EOF
#!/usr/bin/env bash

### Helpers begin
set -o noglob
err() { echo -e "\r${color:+\e[31m}[!] \$*\e[0m\e[K"; }
errx() { err "\${*:2}"; exit "\$1"; }
good() { echo -e "\r${color:+\e[32m}[+] \$*\e[0m\e[K"; }
info() { echo -e "\r${color:+\e[37m}[*] \$*\e[0m\e[K"; }
subinfo() { echo -e "\r${color:+\e[36m}[=] \$*\e[0m\e[K"; }
warn() { echo -e "\r${color:+\e[33m}[-] \$*\e[0m\e[K"; }
### Helpers end

[[ -f "\$1" ]] || err "Image \$1 does not exist"

${autocrop:+convert -trim "\$1" "\$1"}
size="\$(
    convert "\$1" txt:- 2>/dev/null | head -n 1 | \\
    perl -lne '/ ([0-9]+),([0-9]+),/ && print "\$1x\$2"'
)"

if [[ "x$pixel_size" != "x" ]]; then
    height="\${size##*x}"
    ((height /= $pixel_size))
    width="\${size%%x*}"
    ((width /= $pixel_size))
    size="\${width}x\$height"
fi

info "Fixing \$1"
mv "\$1" "\${1%.png}_\$size.png"
EOF
chmod 700 "$script"

# Run sub-script
if [[ -n $parallel ]]; then
    parallel -a "$dataset" --bar --joblog ${resume:++}"$joblog" --lb \
        -P "$threads" -r $resume "$script" {}
    [[ -n $verbose ]] || echo -en "\e[1A\e[K" >&2
else
    count="1"
    while read -r data; do
        echo -e "\r\e[K" >&2
        echo -en "${color:+\e[37m}[$count/$total]\e[0m\e[K\e[1A" >&2
        $script "$data"
        ((count += 1))
    done <"$dataset"; unset data
fi

clean
