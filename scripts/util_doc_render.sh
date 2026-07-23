#!/bin/bash
# =============================================================================
# scripts/util_doc_render.sh
# Single source of truth for rendering DevKit's annotation-driven guides.
#
# Both the host `make help` (scripts/util_make_help.sh) and the in-container
# `h`/`help` (config/util_aliases.sh::__print_help) call this renderer, so the
# guide looks and behaves identically inside and outside the container. All
# spacing/format constants live here — change them once, both surfaces update.
#
# The parser reads `## @section`, `## @<marker>` (target|alias) and `## @arg`
# comment annotations. The hot loop is fork-free (nameref helpers, no per-line
# command substitution) so rendering stays cheap on every login/help call.
# =============================================================================

# Colors/DIM come from util_logging.sh. This file is bundled from the tail of
# util_logging.sh (after the colors are defined), so it must NOT require logging
# back — that would recurse. The render functions only reference colors at call
# time, by which point the caller's environment always has them.

# --- Format constants (single source) ----------------------------------------
: "${DK_ROW_INDENT:=    }"      # entry row indent (4 spaces)
: "${DK_SUB_INDENT:=        }"  # continuation (↳) indent (8 spaces)
: "${DK_SEP:= : }"              # name → description separator
: "${DK_ARROW:=↳}"              # argument continuation marker
: "${DK_SEC_GAP:= }"            # gap between a section emoji and its title

# --- Fork-free helpers -------------------------------------------------------

# __dk_trim <outvar> <value> : strip leading/trailing whitespace (no subshell)
__dk_trim() {
    local -n __o="$1"
    local v="$2"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    __o="$v"
}

# __dk_split_sig <namevar> <argsvar> <signature>
#   Splits a documented signature into its name part and argument part.
#   Everything up to the first argument-like token ([opt], --flag, or an a|b|c
#   value list) is the name (which may be an `a / b` alias pair); the rest are
#   arguments. This lets every entry render the same way: name in the aligned
#   column, arguments (if any) on a `↳` line — matching the host and container.
__dk_split_sig() {
    local -n __n="$1"
    local -n __a="$2"
    local tok in_args=false
    local -a toks
    read -r -a toks <<< "$3"
    __n=""; __a=""
    for tok in "${toks[@]}"; do
        if [ "$in_args" = false ] && { [[ $tok == \[* ]] || [[ $tok == --* ]] || [[ $tok == *"|"* ]]; }; then
            in_args=true
        fi
        if [ "$in_args" = true ]; then
            __a+="${__a:+ }$tok"
        else
            __n+="${__n:+ }$tok"
        fi
    done
}

# __dk_strip_vals <outvar> <args> : drop `=value` enumerations from arg tokens
#   (SIF_MODE=dev|prod|slurm -> SIF_MODE, [ENV=ros|dev] -> [ENV]) so the row
#   stays compact; the accepted values are documented once in the @arg legend.
__dk_strip_vals() {
    local -n __o="$1"
    local out="" tok
    for tok in $2; do
        if [[ $tok == *"="* ]]; then
            local head="${tok%%=*}"
            if [[ $tok == *"]" ]]; then tok="${head}]"; else tok="$head"; fi
        fi
        out+="${out:+ }$tok"
    done
    __o="$out"
}

# devkit_guide_row <col> <name> <desc> [prefix]
#   One aligned `[prefix]name : desc` entry row. The optional prefix (e.g.
#   "make ") sits OUTSIDE the padded name field so the ` : ` column stays aligned
#   regardless of prefix length (the column width is measured on names alone).
devkit_guide_row() {
    printf "${DK_ROW_INDENT}${GREEN}%s%-*s${NC}${DK_SEP}%s\n" "${4:-}" "$1" "$2" "$3"
}

# devkit_guide_subrow <args> : the dim `↳ args` continuation line
devkit_guide_subrow() {
    printf "${DK_SUB_INDENT}${DIM}${DK_ARROW} %s${NC}\n" "$1"
}

# devkit_section_header <emoji> <title> <color> : one section header line
devkit_section_header() {
    printf "\n  ${3}%s${DK_SEC_GAP}%s:${NC}\n" "$1" "$2"
}

# devkit_guide_footer <suffix> : the standard "Type h or help <suffix>" hint,
#   preceded by a blank line. Keeps the h/help reference styled identically
#   everywhere it appears (welcome MOTD, in-container help, ...).
devkit_guide_footer() {
    printf "\n  Type ${CYAN}h${NC} or ${CYAN}help${NC} %s\n" "$1"
}

# devkit_render_guide <file> <marker> <name_prefix> <default_color> [skip_fn]
#   Renders every `## @section` / `## @<marker>` entry from <file>. Column width
#   is derived from the widest visible entry name (never hardcoded). <name_prefix>
#   is placed before each name inside the green (e.g. "make "). <skip_fn>, if
#   given, is called with a section title; a 0 return hides that whole section.
devkit_render_guide() {
    local file="$1" marker="$2" prefix="$3" defcolor="$4" skipfn="${5:-}"
    local line t col=0 skip=false name args sig

    # Pass 1 — derive the column width from visible entry names only.
    while IFS= read -r line; do
        t="${line#"${line%%[![:space:]]*}"}"
        case $t in
            "## @section "*)
                if [ -n "$skipfn" ]; then
                    local st; __dk_trim st "${t#\#\# @section }"; st="${st#*|}"; st="${st%|*}"; __dk_trim st "$st"
                    if "$skipfn" "$st"; then skip=true; else skip=false; fi
                fi ;;
            "## @$marker "*)
                [ "$skip" = true ] && continue
                __dk_trim sig "${t#\#\# @$marker }"; sig="${sig%%:*}"; __dk_trim sig "$sig"
                __dk_split_sig name args "$sig"
                (( ${#name} > col )) && col=${#name} ;;
        esac
    done < "$file"

    # Pass 2 — render.
    skip=false
    while IFS= read -r line; do
        t="${line#"${line%%[![:space:]]*}"}"
        case $t in
            "## @section "*)
                local sd emoji title cname
                __dk_trim sd "${t#\#\# @section }"
                IFS='|' read -r emoji title cname <<< "$sd"
                __dk_trim emoji "$emoji"; __dk_trim title "$title"; __dk_trim cname "$cname"
                if [ -n "$skipfn" ] && "$skipfn" "$title"; then skip=true; continue; fi
                skip=false
                devkit_section_header "$emoji" "$title" "${!cname:-$defcolor}" ;;
            "## @$marker "*)
                [ "$skip" = true ] && continue
                local content desc
                content="${t#\#\# @$marker }"
                __dk_trim sig "${content%%:*}"
                __dk_trim desc "${content#*:}"
                __dk_split_sig name args "$sig"
                devkit_guide_row "$col" "$name" "$desc" "$prefix"
                if [ -n "$args" ]; then
                    local shown; __dk_strip_vals shown "$args"
                    devkit_guide_subrow "$shown"
                fi ;;
        esac
    done < "$file"
}

# devkit_render_arglegend <file> <emoji> <title> [color]
#   Renders the `## @arg NAME | description` legend (host only). Column width is
#   derived from the widest argument key.
devkit_render_arglegend() {
    local file="$1" emoji="$2" title="$3" color="${4:-$BLUE}"
    local line t col=0 key
    local -a keys descs

    while IFS= read -r line; do
        t="${line#"${line%%[![:space:]]*}"}"
        case $t in
            "## @arg "*)
                local body; __dk_trim body "${t#\#\# @arg }"
                local k d; __dk_trim k "${body%% | *}"; __dk_trim d "${body#* | }"
                keys+=("$k"); descs+=("$d")
                (( ${#k} > col )) && col=${#k} ;;
        esac
    done < "$file"

    [ "${#keys[@]}" -eq 0 ] && return 0
    printf "\n  ${color}%s${DK_SEC_GAP}%s:${NC}\n" "$emoji" "$title"
    local i
    for i in "${!keys[@]}"; do
        printf "${DK_ROW_INDENT}${GREEN}%-*s${NC} %s\n" "$col" "${keys[$i]}" "${descs[$i]}"
    done
}
