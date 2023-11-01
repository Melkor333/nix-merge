#!/usr/bin/env bash

shopt -s strict:all 2&>/dev/null || true
set -eo pipefail

local_store="$HOME/.local/share/nix-merge"
cache_file="${local_store}/packages.cache"
state_file="${local_store}/attrsets.cache"


BEGIN="### BEGIN nix-merge"
MIGRATE_ALL=0
USE_DESCRIPTIONS=0
ask_description=1
# Can't do this inside of a function because of global is lost on 'declared -p'


## STATES
_SELECT_STATE=0
_MIGRATIONS_SELECTED=0
_DELETIONS_SELECTED=0

unhandled_packages=()
mapfile -t unhandled_packages < <(nix-env -q)
to_delete_pkgs=()
to_ignore_pkgs=()
to_migrate_pkgs=()
count=0
declare -gA package_attrsets

usage() {
    echo "Usage: $0 [OPTION]... FILE"
    echo "Migrate all your nix-env packages to a configuration file"
    echo ""
    echo "  -a --all            Just select *all* files. otherwise you will be asked"
    echo "  -d --descriptions   Ask for an optional description for each package to be added as comment"
    echo ""
    echo "  FILE                Should be a nix configuration file e.g.:"
    echo "                      /etc/nixos/configuration.nix"
    echo "                      $HOME/.config/home-manager/home.nix"
    echo "                      This file should contain the following line."
    echo "                      new packages will be inserted after this line."
    echo "                      Note that if the line is indented, indentation will"
    echo "                      be used during insertion"
    echo ""
    echo "                      $BEGIN"
    echo ""
    echo ""
    echo "CACHE FILES:"
    echo "$cache_file"
    echo "                    Stores a list of all existing packages it can find"
    echo ""
    echo "$state_file"
    echo "                    Stores the current status of packages-names and what"
    echo "                    packages are yet to be handled in case of early cancel"
}

_contains_element () {
  local e match="$1"
  shift
  for e; do
      if [[ "$e" == "$match" ]]; then
          return 0
      fi
  done
  return 1
}

_update_unhandled() {
    # remove all packages in delete/migrate/ignore from unhandled
    for pkg in "${to_delete_pkgs[@]}" "${to_migrate_pkgs[@]}" "${to_ignore_pkgs[@]}"; do
        unhandled_packages=( "${unhandled_packages[@]/$pkg}" )
    done

}

# Do a first run
firstrun_infos() {
    echo "First, I'll have to do an 'attribute-mapping' from e.g. 'bash-language-server' to 'nodePackage.bash-language-server' for each package."
    echo "Since it's not possible to always determine this myself, I will ask for each package with multiple possible derivations."
    echo "This is done as a first step, because it allows me to automatically remove duplicates when something is already in the configuration file."
    echo '--'
    echo "After that, I'll give a list where each package which should be migrated to NixOS can be selected with <space>"
    echo "Press <Enter> when you selected all the packages you want to migrate"
    echo "You can define a small 'docstring' to be appended to each package. you can also just leave it empty"
    echo "It will be written to the config file in the style 'PACKAGENAME # DESCRIPTION'"
    echo "After that I'll list the leftover pacakges to be selected for deletion"
}

_store_state() {
    _update_unhandled
    # Overwrite the state_file
    {
        declare -p package_attrsets
        declare -p to_delete_pkgs
        declare -p to_ignore_pkgs
        declare -p to_migrate_pkgs
        declare -p _MIGRATIONS_SELECTED >> "$state_file"
        declare -p _DELETIONS_SELECTED >> "$state_file"
    } > "$state_file"
}

# Add a package either to ignore_pkgs or delete_pkgs
# Fail when no answer has been given
_ask_remove_attrset() {
    local status
    local package_name="$1"
    set +e
    gum confirm --affirmative="skip" --negative="Delete" "Do you want to skip or delete package $package_name"
    status=$?
    set -e
    if [[ "$status" = 0 ]]; then
        to_ignore_pkgs+=("$package_name")
    elif [[ "$status" = 1 ]]; then
        to_delete_pkgs+=("$package_name")
    else
        _abort "Aborting due to ctrl+c asking what to do with $package_name"
    fi
    _store_state
}

# Find the name of the attribute set (as used in configuration.nix)
# Do this by starting with the pkg name and keep removing dashes.
# E.g. azure-cli-2.52.0 -> azure-cli -> azure
# Ask for a name if no package is found
# Adds packages either to package_attrsets or indirectly to to_delete_pkgs
_get_attrset() {
    local attrset
    local pkg="$1"
    local name="$1" # Gonna be trimmed until a match is found
    if [ "${package_attrsets[$pkg]+haselement}" ]; then
        # We already have that attrset
        return
    fi
    if [[ ${to_delete_pkgs[@]} =~ ${pkg} ]]; then
        # We already decided to remove that package
        return
    fi
    attrset=$(grep -P "${pkg}([\t \-]|$)" "$cache_file" || true)

    # No attrset found. Maybe the version contains dashes (e.g. bash-2023-05-04).
    # In that case we keep removing dashes; bash-2023-05-04 -> bash-2023-05 -> bash-2023 -> bash
    # Until we find at least one package
    # Maybe not the stronges solution but I guess it works for the moment
    while [[ -z "$attrset" ]]; do
        old_name="$name"
        name="${name%-*}"
        # We can't remove anymore dashes and still don't find an attrset. Maybe the package was installed from an external source
        if [[ "$name" = "$old_name" ]]; then
            echo -ne "No attrset found for $pkg\nPlease find a proper attrset (e.g. on search.nixos.org) and enter it here (empty to skip).\nAn attrset might look like: 'nodePackages.bash-language-server'\n> "
            read -r attrset
            if [[ -z "$attrset" ]]; then
                return 1
            fi
        fi
        attrset=$(grep -P "${name}([\t \-]|$)" "$cache_file" || true)
    done

    # If there are more than one attrset, let the user select a package
    if [[ "$attrset" == *$'\n'* ]]; then
        echo "Need to select the proper attrset for $package (or press ctrl+c)"
        set +eo pipefail
        attrset=$(echo -e "$attrset" | gum choose)
        status=$?
        set -eo pipefail
        if [[ "$status" != 0 || -z "$attrset" ]]; then
            return 1
        fi
    fi
    package_attrsets["$pkg"]="${attrset%% *}"
    _store_state
}

_name() {
    echo "${package_attrsets[$1]}"
}

# TODO: maybe colors or something
_log() {
    echo "$@"
}

_abort() {
    printf "$@\n"
    exit 2
}

_fail() {
    printf "$@\n"
    usage
    exit 2
}

# This is technically unsave, but we trust 'nix-env -q' output now...
_select() {
    if ! [[ "$@" == *" "* ]]; then
        echo "$@"
        return
    fi
    echo "$@" | tr ' ' '\n' | grep -v '^$' | gum choose --no-limit
    _SELECT_STATE=$?
}

_add_to_global_config() {
    local package="$1" description
    prefix=$(grep "${BEGIN}\$" "$global_conf" || true)
    # only keep the spaces before the ###BEGIN
    prefix="${prefix%%#*}" # keep only spaces
    prefix="${prefix// /\\ }" # Spaces must be 'escaped' for sed to insert them
    if [[ "$USE_DESCRIPTIONS" == 1 ]]; then
        echo "Write a description for ${package}: (empty to ignore)"
        description=$(echo "" | gum input) # without the echo it can steal an outer while read input
        if [[ -n "$description" ]]; then
            description=" # $description"
        else
            description=""
        fi
    fi
    $SUDO sed -i "/${BEGIN}/a ${prefix}$(_name "$package")${description}" "$global_conf"
}

_delete() {
    # TODO: This is technically unsafe :|
    nix-env -e $1
}

create_cache() {
    # We need to fetch some packages separately
    # https://github.com/nix-community/nix-index/blob/master/src/listings.rs#L18
    echo "Rebuilding cache file. Going to take a while"
    nix-env -qaP | sed 's/^nixos\.//' > "${cache_file}_new"
    echo "Generating cache for:"
    for attrSet in "xorg" "haskellPackages" "rPackages" "nodePackages" "coqPackages"; do
        echo "- $attrSet"
        nix-env -qaP -A "nixos.$attrSet" | sed 's/^nixos\.//' >> "${cache_file}_new"
    done
    mv "${cache_file}_new" "${cache_file}"
}

_prereq() {
    if [[ -z "$global_conf" ]]; then
        _fail "No config file given!"
    fi
    if ! [[ -f "$global_conf" ]]; then
        _fail "The file $global_conf doesn't exist!"
    fi
    # Use sudo if we don't have write access
    if ! [[ -w "$global_conf" ]]; then
        SUDO=sudo
        echo "script will use sudo to edit the configfile"
    else
        SUDO=
    fi
    if ! grep -q "$BEGIN" "$global_conf"; then
        _fail "The file $global_conf doesn't contain the following line! aborting\n$BEGIN"
    fi
    # setup
    mkdir -p "$local_store"

    # TODO: the find stuff might be broken!
    old_file="$(find "$cache_file" -mtime +7 -print 2&>/dev/null || true)"
    if [[ ! -f "$cache_file" || -n "$old_file" ]]; then
        create_cache
    fi
    if ! [[ -f "$cache_file" ]]; then
        _fail "need the cache file $cache_file"
    fi
    if ! [[ -f "$local_store/last_run" ]]; then
        firstrun_infos
        # Touch last run at the end
        touch "$local_store/last_run"
    fi
    _store_state
}

# Set the count to 0 and and the amount to len(unhandled_packages)
# TODO: give amount as variable! and merge with _update_count (no param=update)
_restart_count() {
    count=0
    amount="${#to_migrate_pkgs[@]}"
    echo "0/$amount"
}

# Print a count X/Y and increment
_update_count() {
    ((count=count+1))
    echo -e '\e[1A\e[K'"$count/$amount"
}

get_attrsets() {
    _restart_count
    for package in "${to_migrate_pkgs[@]}"; do
        if [[ -z "$package" ]]; then
            continue
        fi
        # if it returns != 0, ignore the package
        if ! _get_attrset "$package"; then
            _ask_remove_attrset "$package"
        fi
        _update_count
        _store_state
    done
}

find_migrations() {
    local add
    # Packages which should be moved to the global config
    if [[ "${#unhandled_packages}" -eq 0 ]]; then
        # No packages to migrate
        return
    fi
    if [[ "$MIGRATE_ALL" = 1 ]]; then
        to_migrate_pkgs=(${unhandled_packages[@]})
    else
        echo "Which packages do you want to migrate to the config file? (space to select, enter to move on)"
        mapfile -t add < <(_select "${unhandled_packages[@]}")
        for package in "${add[@]}" ; do
            to_migrate_pkgs+=("$package")
            #to_delete_pkgs+=("$package") # Only delete when they exist globally :)
            # whatever you want to do when array doesn't contain value
        done
    fi
    _store_state
}

find_deletes() {
    local remove
    if [[ "${#unhandled_packages}" -eq 0 ]]; then
        # No packages to delete
        return
    fi
    echo "Which packages do you want to delete? (space to select, enter to move on)"
    mapfile -t remove < <(_select "${unhandled_packages[@]}")
    for package in "${remove[@]}"; do
        to_delete_pkgs+=("$package")
    done
    _store_state
}

print_changes() {
    have_changes=0
    todos="removing the following packages:\n"
    for package in "${to_delete_pkgs[@]}"; do
        todos+="- $package\n"
        have_changes=1
    done
    todos+="migrating the following packages:\n"
    for package in "${to_migrate_pkgs[@]}"; do
        todos+="- $package -> $(_name "$package")\n"
        have_changes=1
    done
    todos+="ignoring the following packages:\n"
    for package in "${to_ignore_pkgs[@]}"; do
        todos+="- $package -> $(_name "$package")\n"
        have_changes=1
    done
    if [[ "$have_changes" == 1 ]]; then
        printf "$todos"
    else
        echo "No changes to do! removing state"
        cleanup_state
        exit 130
    fi

}

do_changes() {
    for package in "${to_migrate_pkgs[@]}"; do
        _add_to_global_config "$package"
    done
    if [[ "${#to_migrate_pkgs[@]}" > 0 ]]; then
        _log "Removing ${to_migrate_pkgs[*]}"
        _delete "${to_migrate_pkgs[*]}"
    fi
    if [[ "${#to_delete_pkgs[@]}" > 0 ]]; then
        _log "Removing ${to_delete_pkgs[*]}"
        _delete "${to_delete_pkgs[*]}"
    fi
    #for package in "${to_migrate_pkgs[@]}"; do
    #    _log "removing from env: $package"
    #    _delete "$package"
    #done
    #for package in "${to_delete_pkgs[@]}"; do
    #    _log "removing from env: $package"
    #    _delete "$package"
    #done
}

cleanup_state() {
    _log "removing $state_file"
    rm "$state_file"
}

#cleanup_state
while getopts ad-: OPT; do
  # support long options: https://stackoverflow.com/a/28466267/519360
  if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
    OPT="${OPTARG%%=*}"       # extract long option name
    OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
    OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
  fi
  case "$OPT" in
    a | all )           MIGRATE_ALL=1 ;;
    d | descriptions )  USE_DESCRIPTIONS=1 ;;
    ??* )               _fail "Illegal option --$OPT" ;;            # bad long option
    ? )                 exit 2 ;;  # bad short option (error reported via getopts)
  esac
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list
# TODO: argparse
if [ "$#" -gt 1 ]; then
    _fail "Too many arguments. Filename must be at the end"
fi
global_conf="$1"

# Needs to be run outside of a function
if [[ -f "$state_file" ]]; then
    _log "Found state file: $state_file"
    _log "continuing from there..."
    source "$state_file"
fi

_prereq
if [[ "$_MIGRATIONS_SELECTED" != 1 ]]; then
    if [[ "${#to_migrate_pkgs}" -gt 0 ]]; then
        _log "already selected the following packages for migration:"
        _log "${to_migrate_pkgs[@]}"
    fi
    find_migrations
    # If the select was cancelled, we want to ask again a next time
    # Otherwise, don't repeat this task.
    if [[ _SELECT_STATE == 0 ]]; then
        _MIGRATIONS_SELECTED=1
    fi
else
    _log "Selection already done"
fi
get_attrsets
if [[ "$_DELETIONS_SELECTED" != 1 ]]; then
    find_deletes
    # If the select was cancelled, we want to ask again a next time
    # Otherwise, don't repeat this task.
    if [[ _SELECT_STATE == 0 ]]; then
        _DELETIONS_SELECTED=1
    fi
else
    _log "Selection already done"
fi
print_changes
set +e
gum confirm --affirmative="Apply" --negative="Cancel" "Do you want to do the changes?"
if [[ "$?" != '0' ]]; then
    _abort "Not doing the changes."
fi
set -e
do_changes
cleanup_state
