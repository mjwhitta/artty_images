#!/usr/bin/env bash

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
err() { echo -e "${color:+\e[31m}[!] $*${color:+\e[0m}" >&2; }
errx() { err "${*:2}"; exit "$1"; }
good() { echo -e "${color:+\e[32m}[+] $*${color:+\e[0m}"; }
info() { echo -e "${color:+\e[37m}[*] $*${color:+\e[0m}"; }
long_opt() {
    local arg shift="0"
    case "$1" in
        "--"*"="*) arg="${1#*=}"; [[ -n $arg ]] || return 127 ;;
        *) shift="1"; shift; [[ $# -gt 0 ]] || return 127; arg="$1" ;;
    esac
    echo "$arg"
    return "$shift"
}
subinfo() { echo -e "${color:+\e[36m}[=] $*${color:+\e[0m}"; }
warn() { echo -e "${color:+\e[33m}[-] $*${color:+\e[0m}"; }
### Helpers end

get_categories() {
    curl -k -L -s "$url/$begin" | \
        grep -i -o -P -s "href\=\"/wiki/Category:\K[^\"?]+" | sort -u
}

get_file() {
    local category="${1%_Monster_Icons}"
    local file="$2"
    local final="$(normalize "$category" "$file")"
    local img
    local q="controller=Lightbox&method=getMediaDetail&format=json"

    if [[ ! -f "$final" ]]; then
        img="$(
            curl -L -s "${url}a.php?$q&fileTitle=$file" | \
            jq -c -M -r -S ".imageUrl"
        )"

        mkdir -p "$(dirname "$final")"
        curl -L -o "$final" -s "$img"
    fi

    case "$(file "$final")" in
        *" PNG "*) ;;
        *" RIFF "*)
            mv "$final" "${final%.png}.webp"
            convert -depth 8 "${final%.png}.webp" "$final"
            rm -f "${final%.png}.webp"
            ;;
        *" SVG "*)
            mv "$final" "${final%.png}.svg"
            convert -depth 8 "${final%.png}.svg" "$final"
            rm -f "${final%.png}.svg"
            ;;
    esac
}

get_files() {
    curl -k -L -s "$url/Category:$1" | \
        grep -i -o -P -s "href\=\"/wiki/File:\K[^\"?]+" | sort -u
}

normalize() {
    local category="$1"
    local file="$2"

    case "$category" in
        "MHFG") file="${file#FrontierGen-}" ;;
        "MHFU")
            category="${file%%-*}"
            file="${file#$category-}"
            ;;
        "Monster_Icons")
            category="${file%%-*}"
            file="${file#$category-}"
            case "$category" in
                "FrontierGen") category="misc/MHFG" ;;
                *) category="misc/$category" ;;
            esac
            ;;
        *) file="${file#$category-}"
    esac

    case "$file" in
        *".png") ;;
        *"."*) file="${file%.*}.png" ;;
        *) file="$file.png" ;;
    esac

    echo "$category/${file,,}"
}

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

DESCRIPTION
    Fetch Monster Hunter icons.

OPTIONS
    -h, --help         Display this help message
        --no-color     Disable colorized output

EOF
    exit "$1"
}

declare -a args
unset help
begin="Category:Monster_Icons"
color="true"
url="https://monsterhunter.fandom.com/wiki"

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        "--") shift; args+=("$@"); break ;;
        "-h"|"--help") help="true" ;;
        "--no-color") unset color ;;
        *) args+=("$1") ;;
    esac
    case "$?" in
        0) ;;
        1) shift ;;
        *) usage "$?" ;;
    esac
    shift
done
[[ ${#args[@]} -eq 0 ]] || set -- "${args[@]}"

# Help info
[[ -z $help ]] || usage 0

# Check for missing dependencies
declare -a deps
deps+=("convert")
deps+=("curl")
deps+=("grep")
deps+=("jq")
check_deps

# Check for valid params
[[ $# -eq 0 ]] || usage 1

while read -r category; do
    echo "- $category"

    while read -r file; do
        case "$file" in
            *".png"|*".webp")
                echo " \\_ $file"
                get_file "$category" "$file"
                ;;
        esac
    done < <(get_files "$category"); unset file

    # Do SVGs last
    while read -r file; do
        case "$file" in
            *".svg")
                echo " \\_ $file"
                get_file "$category" "$file"
                ;;
        esac
    done < <(get_files "$category"); unset file
done < <(get_categories); unset category

# Merge misc
while read -r img; do
    if [[ ! -f "./${img#./misc/}" ]]; then
        mkdir -p "$(dirname "./${img#./misc/}")"
        mv "$img" "./${img#./misc/}"
    fi
done < <(find ./misc -type f -print); unset img

rm -f -r ./misc

# Delete empty files (1x) and folders (2x)
find . -empty -delete
find . -empty -delete
