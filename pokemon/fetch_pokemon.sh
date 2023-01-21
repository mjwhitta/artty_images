#!/usr/bin/env bash

### Helpers begin
set -o noglob
trap "clean 128" SIGINT # Ensure cleanup on ^C
check_deps() {
    for d in "${deps[@]}"; do
        [[ -n $(command -v "$d") ]] || errx 127 "$d is not installed"
    done; unset d
}
check_lock() {
    [[ -n $cache ]] || errx 126 "Cache is not defined"
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
err() { echo -e "${color:+\e[31m}[!] $*\e[0m"; }
errx() { err "${*:2}"; clean "$1"; }
good() { echo -e "${color:+\e[32m}[+] $*\e[0m"; }
hide_cursor() { echo -en "\e[?25l"; }
info() { echo -e "${color:+\e[37m}[*] $*\e[0m"; }
json_get() {
    if [[ -z $json ]] || [[ ! -f "$json" ]]; then
        return
    fi
    jq -cr ".$*" "$json" | sed -r "s/^null$//g"
}
long_opt() {
    local arg shift="0"
    case "$1" in
        "--"*"="*) arg="${1#*=}"; [[ -n $arg ]] || usage 123 ;;
        *) shift="1"; shift; [[ $# -gt 0 ]] || usage 123; arg="$1" ;;
    esac
    echo "$arg"
    return $shift
}
show_cursor() { echo -en "\e[?25h"; }
subinfo() { echo -e "${color:+\e[36m}[=] $*\e[0m"; }
warn() { echo -e "${color:+\e[33m}[-] $*\e[0m"; }
### Helpers end

read_resume_file() {
    wait="$(json_get "start")"
    stop="$(json_get "stop")"
}

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS] [stop]

Download Pokemon spites.

Options:
    -h, --help           Display this help message
    --no-color           Disable colorized output
    -r, --resume         Resume from a previous run
    -s, --start=NUM      Start at Pokedex entry NUM
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

    cat >"$json" <<EOF
{
  "start": "$wait",
  "stop": "$stop"
}
EOF
}

declare -a args deps
unset help
color="true"
deps+=("convert")
deps+=("curl")
deps+=("jq")
parallel="true"
stop="386"
threads="32"
wait="1"
wiki="https://bulbapedia.bulbagarden.net/wiki"
dex="$wiki/List_of_Pok%C3%A9mon_by_National_Pok%C3%A9dex_number"

# Check for missing dependencies
check_deps

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift && args+=("$@") && break ;;
        "-h"|"--help") help="true" ;;
        "--no-color") unset color ;;
        "-r"|"--resume") resume="--resume" ;;
        "-s"|"--start"*) wait="$(long_opt "$@")" || shift ;;
        "-t"|"--threads"*) threads="$(long_opt "$@")" || shift ;;
        "-v"|"--verbose") verbose="true" ;;
        *) args+=("$1") ;;
    esac
    shift
done
[[ ${#args[@]} -eq 0 ]] || set -- "${args[@]}"

# Check for valid params
[[ -z $help ]] || usage 0
[[ $# -le 1 ]] || [[ -n $resume ]] || usage 1

# Determine parallel situation
if [[ -n $parallel ]] && [[ -z $(command -v parallel) ]]; then
    warn "Parallel is not installed, defaulting to single-threaded"
    unset parallel
fi

# Cite if needed
if [[ -n $parallel ]] && [[ ! -f "$HOME/.parallel/will-cite" ]]; then
    pvers="$(parallel --version | grep -ioPs "parallel \K\d+")"
    if [[ $pvers -lt 20181122 ]]; then
        mkdir -p "$HOME/.parallel"
        parallel --citation
    fi
    unset pvers
fi

# Save command line args
[[ $# -eq 0 ]] || stop="$1"

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

    declare -a pokedex; unset start
    while read -r line; do
        case "$line" in
            *"Bulbasaur"*) start="true" ;;
        esac
        [[ -z $start ]] || pokedex+=("$line")
    done < <(curl -kLs "$dex"); unset line

    count="0"
    while read -r link; do
        ((count += 1))
        [[ $count -lt $wait ]] || echo "$link" >>"$dataset"
        [[ $count -lt $stop ]] || break
    done < <(
        echo "${pokedex[@]}" | \
        grep -oPs "/wiki/\K\S+_\(Pok%C3%A9mon\)" | uniq
    )
    unset pokedex
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


#####################
# Game       | Code
# ----       | ----
# Emerald    | 3e
# Leafgreen  | 3f, 3r
#####################

adjust_key() {
    local key="\${1%.png}"
    key="\${key/Spr_3e/emerald}"
    key="\${key/Spr_3f/leafgreen}"
    key="\${key/Spr_3r/leafgreen}"
    echo "\$key"
}

download() {
    game="\${1%%_*}"
    dir="\$game/\$gen"
    fn="\$id-\$name"

    if [[ "\$game" != "sprites" ]]; then
        case "\$1" in
            *"_s") fn+="-shiny" ;;
        esac

        if [[ \$index -eq 141 ]] || [[ \$index -eq 142 ]]; then
            case "\$1" in
                *"_f") fn+="-fossil" ;;
            esac
        elif [[ \$index -eq 201 ]]; then
            fn="\${fn%-shiny}"
            case "\$1" in
                *"EX"*) fn+="-exclamation" ;;
                *"QU"*) fn+="-question" ;;
                *"B"*) fn+="-B" ;;
                *"C"*) fn+="-C" ;;
                *"D"*) fn+="-D" ;;
                *"E"*) fn+="-E" ;;
                *"F"*) fn+="-F" ;;
                *"G"*) fn+="-G" ;;
                *"H"*) fn+="-H" ;;
                *"I"*) fn+="-I" ;;
                *"J"*) fn+="-J" ;;
                *"K"*) fn+="-K" ;;
                *"L"*) fn+="-L" ;;
                *"M"*) fn+="-M" ;;
                *"N"*) fn+="-N" ;;
                *"O"*) fn+="-O" ;;
                *"P"*) fn+="-P" ;;
                *"Q"*) fn+="-Q" ;;
                *"R"*) fn+="-R" ;;
                *"S"*) fn+="-S" ;;
                *"T"*) fn+="-T" ;;
                *"U"*) fn+="-U" ;;
                *"V"*) fn+="-V" ;;
                *"W"*) fn+="-W" ;;
                *"X"*) fn+="-X" ;;
                *"Y"*) fn+="-Y" ;;
                *"Z"*) fn+="-Z" ;;
                *) fn+="-A" ;;
            esac
            case "\$1" in
                *"_s") fn+="-shiny" ;;
            esac
        elif [[ \$index -eq 351 ]]; then
            fn="\${fn%-shiny}"
            case "\$1" in
                *"_s") fn+="-normal-shiny" ;;
                *"H") fn+="-snowy" ;;
                *"R") fn+="-rainy" ;;
                *"S") fn+="-sunny" ;;
                *) fn+="-normal" ;;
            esac
        elif [[ \$index -eq 386 ]]; then
            fn="\${fn%-shiny}"
            case "\$1" in
                *"A"*) fn+="-attack" ;;
                *"D"*) fn+="-defense" ;;
                *"S"*) fn+="-speed" ;;
            esac
            case "\$1" in
                *"_s") fn+="-shiny" ;;
            esac
        fi
    else
        dir="sprite/\$gen"

        if [[ \$index -eq 201 ]]; then
            case "\$1" in
                "sprites"*"EXMS")
                    fn="\${fn/\$name/\$name-exclamation}" ;;
                "sprites"*"QUMS")
                    fn="\${fn/\$name/\$name-question}" ;;
                "sprites"*"BMS") fn="\${fn/\$name/\$name-B}" ;;
                "sprites"*"CMS") fn="\${fn/\$name/\$name-C}" ;;
                "sprites"*"DMS") fn="\${fn/\$name/\$name-D}" ;;
                "sprites"*"EMS") fn="\${fn/\$name/\$name-E}" ;;
                "sprites"*"FMS") fn="\${fn/\$name/\$name-F}" ;;
                "sprites"*"GMS") fn="\${fn/\$name/\$name-G}" ;;
                "sprites"*"HMS") fn="\${fn/\$name/\$name-H}" ;;
                "sprites"*"IMS") fn="\${fn/\$name/\$name-I}" ;;
                "sprites"*"JMS") fn="\${fn/\$name/\$name-J}" ;;
                "sprites"*"KMS") fn="\${fn/\$name/\$name-K}" ;;
                "sprites"*"LMS") fn="\${fn/\$name/\$name-L}" ;;
                "sprites"*"MMS") fn="\${fn/\$name/\$name-M}" ;;
                "sprites"*"NMS") fn="\${fn/\$name/\$name-N}" ;;
                "sprites"*"OMS") fn="\${fn/\$name/\$name-O}" ;;
                "sprites"*"PMS") fn="\${fn/\$name/\$name-P}" ;;
                "sprites"*"QMS") fn="\${fn/\$name/\$name-Q}" ;;
                "sprites"*"RMS") fn="\${fn/\$name/\$name-R}" ;;
                "sprites"*"SMS") fn="\${fn/\$name/\$name-S}" ;;
                "sprites"*"TMS") fn="\${fn/\$name/\$name-T}" ;;
                "sprites"*"UMS") fn="\${fn/\$name/\$name-U}" ;;
                "sprites"*"VMS") fn="\${fn/\$name/\$name-V}" ;;
                "sprites"*"WMS") fn="\${fn/\$name/\$name-W}" ;;
                "sprites"*"XMS") fn="\${fn/\$name/\$name-X}" ;;
                "sprites"*"YMS") fn="\${fn/\$name/\$name-Y}" ;;
                "sprites"*"ZMS") fn="\${fn/\$name/\$name-Z}" ;;
                "sprites"*"MS") fn="\${fn/\$name/\$name-A}" ;;
            esac
        elif [[ \$index -eq 351 ]]; then
            case "\$1" in
                "sprites"*"HMS") fn="\${fn/\$name/\$name-snowy}" ;;
                "sprites"*"RMS") fn="\${fn/\$name/\$name-rainy}" ;;
                "sprites"*"SMS") fn="\${fn/\$name/\$name-sunny}" ;;
                "sprites"*"MS") fn="\${fn/\$name/\$name-normal}" ;;
            esac
        elif [[ \$index -eq 386 ]]; then
            case "\$1" in
                "sprites"*"AMS") fn="\${fn/\$name/\$name-attack}" ;;
                "sprites"*"DMS") fn="\${fn/\$name/\$name-defense}" ;;
                "sprites"*"SMS") fn="\${fn/\$name/\$name-speed}" ;;
            esac
        else
            case "\$1" in
                "sprites"*"AMS") fn="\${fn/-\$name/-alolan-\$name}" ;;
            esac
        fi
    fi

    if [[ -n \$fn ]]; then
        good "pokemon-\${dir////-}-\$fn"
        fn="\${fn//-/_}"
        curl -kLo "\$dir/\$fn.png" -s "\$2"
        if [[ \$? -eq 0 ]]; then
            convert -trim "\$dir/\$fn.png" "\$dir/\$fn.png" \\
                2>/dev/null
            local size="\$(
                convert "\$dir/\$fn.png" txt:- 2>/dev/null | \\
                head -n 1 | grep -ioPs "\s\K\d+,\d+(?=,)"
            )"
            mv "\$dir/\$fn.png" "\$dir/\${fn}_\${size/,/x}.png"
        else
            err "Failed: \$fn"
        fi
    fi
}

get_gen() {
    if [[ \$index -le 151 ]]; then
        echo "I"
    elif [[ \$index -le 251 ]]; then
        echo "II"
    elif [[ \$index -le 386 ]]; then
        echo "III"
    else
        errx 1 "Unsupported ID: \$id"
    fi
}

get_image() {
    local -A images
    local rgx="(3[efr])"
    local fnrgx="(Spr_\${rgx}_)?\$id\S{0,2}((_\S+?)?|MS)\.png"

    local data key val
    while read -r data; do
        key="\$(adjust_key "\${data%%|*}")"
        val="\${data#*|}"
        [[ -n \${images["\$key"]} ]] || images["\$key"]="\$val"
    done < <(
        curl -kLs "$wiki/\$1" | \\
        grep -oPs "(File:\K|cdn\S+?)\$fnrgx" | \\
        uniq | head -n 2 | sed "N;s/\n/|https:\/\//" | \\
        sort -k 7.5 -t "/" -u
    ); unset data key val

    for key in "\${!images[@]}"; do
        echo "\$key \${images["\$key"]}"
    done; unset key
}

get_images() {
    local -A images
    local rgx="(3[efr])"
    local fnrgx="Spr_\${rgx}_\$id\S{0,2}(_\S+?)?\.png"

    # Get initial images
    local key val
    while read -r key val; do
        key="\$(adjust_key "\$key")"
        [[ -n \${images["\$key"]} ]] || images["\$key"]="\$val"
    done < <(
        curl -kLs "$wiki/\$1" | \\
        grep -oPs "(File:\K|cdn\S+?)\$fnrgx" | \\
        sed "N;s/\n/ https:\/\//" | sort -k 7.5 -t "/" -u
    ); unset key val

    # Add missing images
    if [[ \$index -eq 201 ]]; then
        while read -r key val; do
            images["\$key"]="\$val"
        done < <(
            for l in \\
                B C D E F G H I J K L M N O P Q R S T U V W X Y Z \\
                EX QU
            do
                for code in 3e 3f; do
                    get_image "File:Spr_\${code}_\$id\$l.png"
                    get_image "File:Spr_\${code}_\$id\${l}_s.png"
                done; unset code
            done; unset l
        ); unset key val
    elif [[ \$index -eq 351 ]]; then
        images["emerald_351H"]="\${images["leafgreen_351H"]}"
        images["emerald_351R"]="\${images["leafgreen_351R"]}"
        images["emerald_351S"]="\${images["leafgreen_351S"]}"
    fi

    # Get sprites too
    while read -r key val; do
        key="\$(adjust_key "\$key")"
        [[ -n \${images["\$key"]} ]] || images["\$key"]="\$val"
    done < <(get_sprites); unset key val

    # Loop thru images fixing bad leafgreen images
    local bad
    for key in "\${!images[@]}"; do
        if [[ \$index -gt 151 ]] &&
           [[ \$index -le 251 ]] &&
           [[ \$index -ne 216 ]]
        then
            bad="true"
        elif [[ \$index -eq 352 ]]; then
            bad="true"
        fi

        if [[ -z \$bad ]]; then
            echo "\$key \${images["\$key"]}"
        else
            echo "\$key \${images["\${key/leafgreen/emerald}"]}"
        fi
    done; unset key
}

get_sprites() {
    local sprite
    while read -r sprite; do
        echo "sprites_\${sprite##*/} \$sprite"
    done < <(
        curl -kLs "$dex" | \
        grep -oPs "cdn\S+?\${id}\S?MS\.png" | sort -u
    ); unset sprite

    # Add missing sprites
    if [[ \$index -eq 201 ]]; then
        while read -r key val; do
            echo "sprites_\$key \$val"
        done < <(
            for l in \\
                B C D E F G H I J K L M N O P Q R S T U V W X Y Z \\
                EX QU
            do
                get_image "File:201\${l}MS.png"
            done; unset l
        ); unset key val
    fi
}

# Grab metadata from link
data="\$(
    curl -kLs "$wiki/\$1" | \\
    grep -m 1 -oPs "File:\K\d{3}.+?(?=\.png)" | \\
    tr "[:upper:]" "[:lower:]" | \\
    sed -r -e "s/%[0-9]{2}//g" -e "s/\./-/g" -e "s/[^-a-z0-9]+//g"
)"

# Parse id and name
id="\${data:0:3}"
name="\${data:3}"

# Remove leading 0s for valid integer index
shopt -s extglob
index="\${id##+(0)}"
shopt -u extglob

# Determine generation from index
gen="\$(get_gen)"

mkdir -p {emerald,leafgreen,sprite}/"\$gen"

# Get a list of all unique images
declare -A images
while read -r key val; do
    images["\$key"]="\$val"
done < <(get_images "\$1"); unset key val

# Loop thru images
for key in "\${!images[@]}"; do
    download "\$key" "\${images["\$key"]}"
done; unset key
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
