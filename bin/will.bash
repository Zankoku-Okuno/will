#!/bin/bash
set -e

# FIXME: arg parsing should detect `--` as end-of-options
# FIXME: global options should be available for use after the command

version=0.2.0

usage="usage $0 [global options] <command> [args]"'

Global Options:
  --help       display this help text and exit
  --version    display version and exit

Commands:
  info [options] <pkgs...>
    check if packages exist and list available actions
    fail if any package does not exist
    -s, --scan    also check package is installed ok
    -a, --all     display info for every known package
  check <pkgs...>
    check if the package is installed (by running the check script)
  up <pkgs...>
    attempt to install packages
'


main() {
  setDefaults
  while getPreCmdOpt; do :; done
  getCmd
  "args_$command"
  "run_$command"
}

###### Command Implementations ######

datadir="${XDG_DATA_DIR:-$HOME/.local/share}/will"
  libdir="$datadir/libs"
  logdir="$datadir/logs"
datadir="${XDG_DATA_DIR:-$HOME/.local/share}/will"
confdir="${XDG_CONFIG_HOME:-$HOME/.config}/will"
  sourcesfile="$confdir/sources"

checkscript=check.sh
collectionfile=collection
alternatesfile=alternates
installscript=install
installDepsfile=deps-up
runDepsfile=deps
submodulelist=manifest

# TODO: update contents of the will lib folder based on a repos file
# while IFS= read -r LINE || [[ -n "$LINE" ]]; do
#   echo "$LINE"
# done <"$HOME/.will/repos"

run_info() {
  local exitCode=0
  if [[ -n "$all" ]]; then
    cd "$libdir"
    # FIXME look through libraries, and remember not to shadow
    local found=' '
    for lib in *; do
      for pkg in "$lib/"*; do
        local pkgName
        pkgName="$(basename "$pkg")"
        if ! echo "$found" | grep -qF " $pkgName "; then
          run_info1 "$pkgName" || :
          found+="$pkgName "
        fi
      done
    done
    exit 0
  else
    for pkg in "${pkgs[@]}"; do
      run_info1 "$pkg" || exit "$?"
    done
  fi
}
run_info1() {
  local pkgName="$1"
  local pkg
  pkg="$(findPkg "$pkgName")"
  if [ -z "$pkg" ]; then
    echo >&2 "no such package found: $pkgName"
    return 1
  fi
  local ok check collection alternates up down installDeps runDeps submodules
  local extraOutput=''
  # Q: is there the ability to check the install?
  check="$([[ -f "$pkg/$checkscript" ]] && echo ' check')"
  # Q: Is this a collection or alternates package?
  collection="$([[ -f "$pkg/$collectionfile" ]] && echo ' collection')"
  alternates="$([[ -f "$pkg/$alternatesfile" ]] && echo ' alternates')"
  # Q: does this module have submodules?
  submodules="$([[ -f "$pkg/$submodulelist" ]] && echo ' submodules')"
  if [[ -n "$scan" ]]; then
    if [[ -n "$check" ]]; then
  # Q: when scanning and can check, report install status
      local exitCode=0
      extraOutput+="$(run_check1 "$pkgName" 2>&1)"
      exitCode="$?"
      if [ $exitCode -eq 0 ]; then
        ok=" $(guardTput setaf 2)OK$(guardTput sgr0)"
      else
        ok=" $(guardTput bold)$(guardTput setaf 1)NO$(guardTput sgr0)"
      fi
    elif [[ -n "$collection" ]]; then
      local missing=''
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(echo "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
        case "$line" in
          ''|'#'*) continue ;;
          *)
            if ! run_check1 "$line" 2>/dev/null; then
              missing+=" $line"
            fi
          ;;
        esac
      done <"$pkg/$collectionfile"
      if [[ -z "$missing" ]]; then
        ok=" $(guardTput setaf 2)OK$(guardTput sgr0)"
      else
        ok=" $(guardTput bold)$(guardTput setaf 1)NO$(guardTput sgr0)"
        extraOutput+="packages missing:$missing"
      fi
    elif [[ -n "$alternates" ]]; then
      die "unimplemented: alternates packages"
    else
      ok=" $(guardTput setaf 6)--$(guardTput sgr0)"
    fi
  fi
  # Q: is there an install script?
  up="$([[ -x "$pkg/$installscript" ]] && echo ' up')"
  # TODO Q: is there an install log for uninstalling?
  # Q: are there any dependencies?
  installDeps="$([[ -f "$pkg/$installDepsfile" ]] && echo ' deps.up')"
  runDeps="$([[ -f "$pkg/$runDepsfile" ]] && echo ' deps.run')"

  echo "$pkgName$ok$check$collection$alternates$up$down$runDeps$installDeps$submodules"
  if [ -n "$extraOutput" ]; then
    sed 's/^/  /' <(echo "$extraOutput") >&2
  fi
  # recurse into submodules if we're scanning with recursion on
  if [[ -n "$submodules" && -n "$scan" && -n "$recursive" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="$(echo "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
      case "$line" in
        ''|'#'*) continue ;;
        *)
          run_info1 "$pkgName/$line"
        ;;
      esac
    done <"$pkg/$submodulelist"
  fi
}

run_check() {
  for pkg in "${pkgs[@]}"; do
    if [[ ! -e "$libdir/$pkg/$checkscript" ]]; then
      die "no check script for '$pkg'"
    fi
    run_check1 "$pkg" || die
  done
}
run_check1() {
  local pkgName="$1"
  local pkg
  pkg="$(findPkg "$pkgName")"
  if [ -z "$pkgName" ]; then
    echo >&2 "no such package found: $pkgName"
    return 1
  fi
  local ec
  if [[ ! -e "$pkg/$checkscript" ]]; then
    return 1
  fi
  (
    cd "$pkg"
    exec sh "$checkscript"
  ) >/dev/null
  ec="$?"
  [ "$ec" -eq 0 ] || return "$ec"
  # warn about any missing run-time dependencies, but carry on even if missing
  if [[ -f "$pkg/$runDepsfile" ]]; then
    local dep
    while IFS= read -r dep || [[ -n "$dep" ]]; do
      dep="$(echo "$dep" | sed -e 's/^\s*//' -e 's/\s*$//')"
      case "$dep" in
        ''|'#'*) continue ;;
        *)
          run_check1 "$dep" || echo >&2 "$(guardTput bold)$(guardTput setaf 3)[WARN]$(guardTput sgr0) will $pkgName: missing runtime dependency: $dep"
        ;;
      esac
    done <"$pkg/$runDepsfile"
  fi
}

run_up() {
  local exitCode okPkgs failPkgs
  local pkg
  for pkg in "${pkgs[@]}"; do
    run_up1 "$pkg"
    exitCode="$?"
    if [[ "$exitCode" -eq 0 ]]; then
      okPkgs+=" $pkg"
    else
      failPkgs+=" $pkg"
    fi
  done
  if [[ -n "$okPkgs" ]]; then echo >&2 "the following packages installed successfully:$okPkgs"; fi
  if [[ -n "$failPkgs" ]]; then die "[ERROR] the following packages failed to install:$failPkgs"; fi
}
run_up1() {
  local exitCode
  local pkgName="$1"
  local pkg
  pkg="$(findPkg "$pkgName")"
  # the package must be found
  if [ -z "$pkg" ]; then
    echo >&2 "no such package found: $1"
    return 1
  fi
  # the package must be installable
  if [[ ! -x "$pkg/$installscript" ]]; then
    echo >&2 "no install script for '$pkgName'"
    return 1
  fi
  # the package must be checkable
  if [[ ! -f "$pkg/$checkscript" ]]; then
    echo >&2 "no check script for '$pkgName'"
    return 1
  fi
  # skip if already available
  if run_check1 "$pkgName"; then
    echo >&2 "skipping already-up package '$pkgName'"
    return 0
  fi
  # warn about any missing install-time dependencies, but carry on even if missing
  if [[ -f "$pkg/$installDepsfile" ]]; then
    local dep
    while IFS= read -r dep || [[ -n "$dep" ]]; do
      dep="$(echo "$dep" | sed -e 's/^\s*//' -e 's/\s*$//')"
      case "$dep" in
        ''|'#'*) continue ;;
        *)
          run_check1 "$dep" || echo >&2 "$(guardTput bold)$(guardTput setaf 3)[WARN]$(guardTput sgr0) will $pkgName: missing install dependency: $dep"
        ;;
      esac
    done <"$pkg/$installDepsfile"
  fi
  mkdir -p "$logdir/$pkgName"
  (
    cd "$pkg"
    # NOTE the following redirects are informed by https://serverfault.com/a/63708
    exec "./$installscript" 3>&1 1>"$logdir/$pkgName/installed-files.log" 2>&3 | tee "$logdir/$pkgName/error.log" >&2
  )
  # make sure the install script succeeded
  exitCode="$?"
  if [[ "$exitCode" -ne 0 ]]; then return "$exitCode"; fi
  # make sure the install script made the package available
  if ! run_check1 "$pkgName"; then
    echo >&2 "install script did not bring up '$pkgName'"
    return 1
  fi
}

run_update() {
  local source tmpdir
  local source_i=0
  # set up working space
  tmpdir="/tmp/will-$(date '+%Y-%m-%d-%H-%M-%S')"
  trap "rm -rf $tmpdir" EXIT
  mkdir "$tmpdir"
  mkdir "$tmpdir/new"
  mkdir "$tmpdir/repos"
  # build each source into the new library directory
  while IFS= read -r source || [[ -n "$source" ]]; do
    source="$(echo "$source" | sed -e 's/^\s*//' -e 's/\s*$//')"
    dest="$(echo "$source" | cut -d' ' -f 3)"
    case "$source" in
      ''|'#'*) continue ;;
      'git -d='*)
        local repo subdir
        repo="$(echo "$source" | cut -d' ' -f 4)"
        subdir="$(echo "$source" | cut -d' ' -f 2 | cut -c 4-)"
        echo >&2 "$repo $subdir -> $dest"
        git clone "$repo" "$tmpdir/repos/$source_i"
        mkdir "$tmpdir/new/$dest"
        cp -r "$tmpdir/repos/$source_i/$subdir/"* "$tmpdir/new/$dest" # FIXME be smarter about merging libraries
      ;;
      'git '*) die "unimplemented: plain git source" ;;
      'file '*) die "unimplemented: local file source" ;;
      # TODO: a compressed file from the internet
      *)
        
      ;;
    esac
    source_i=$((source_i + 1))
  done <"$sourcesfile"
  # backup old package library and install the new one
  mkdir -p "$datadir"
  rm -rf "$libdir.bak"
  mv "$libdir" "$libdir.bak" 2>/dev/null || true
  if mv "$tmpdir/new" "$libdir"; then
    return 0
  else
    mv "$libdir.bak" "$libdir" 2>/dev/null || true
    die "update failed"
  fi
}

###### Helper Functions ######

findPkg() {
  local pkg="$1"
  local trace=''
  for lib in "$libdir"/*; do
    trace+="$(printf '%s\n' "$lib" "$lib/$pkg")"
    if [[ -d "$lib/$pkg" ]]; then
      echo "$lib/$pkg"
      return 0
    fi
  done
  echo >&2 "$trace"
}

###### Parse Arguments ######

# Variables set:
#   $color: boolean, default on if output is a terminal; also set by -C,--color, cleared by --no-color
#
#   $command: by getCmd
#   $pkgs[]: list of packages to operate on
#   $pkg: package to operate on (if only one is allowed)
#
#   $all: boolean, default off
#   $scan: boolean, default off
#   $recursive: boolean, default off

setDefaults() {
  if [ -t 1 ]; then
    color=1
  fi
}

getPreCmdOpt() {
  if [[ "${#args[@]}" -eq 0 ]]; then return 1; fi
  local arg="${args[0]}"
  case "$arg" in
    -C|--color) color=1 ;;
    --no-color) color= ;;
    --help)
      echo "$usage"
      exit 0
    ;;
    --version)
      echo "will v$version"
      exit 0
    ;;
    -*)
      die "unknown option '$arg'"
    ;;
    *) return 1;;
  esac
  args=("${args[@]:1}")
}

getCmd() {
  if [[ "${#args[@]}" -eq 0 ]]; then
    die "command required"
  fi
  local arg="${args[0]}"
  case "$arg" in
    check|info|up|update)
      command=$arg
      ;;
    *) die "unknown command '$arg'"
  esac
  args=("${args[@]:1}")
}


args_check() {
  pkgs=("${args[@]}")
  args=()
}
args_info() {
  while [[ "${#args[@]}" -gt 0 ]]; do
    popArg
    case "$arg" in
      -a|--all) all=1 ;;
      -r|--recursive) recursive=1 ;;
      -s|--scan) scan=1 ;;
      -*)
        die "unrecognized info option '$arg'"
      ;;
      *)
        pkgs=("${pkgs[@]}" "$arg")
      ;;
    esac
  done
}
args_up() {
  pkgs=("${args[@]}")
  args=()
}
args_update() {
  if [[ "${#args[@]}" -gt 0 ]]; then
    die "unrecognized update option '${args[0]}'"
  fi
}

popArg() {
  arg="${args[0]}"
  args=("${args[@]:1}")
  if [[ "$arg" =~ ^(-[^-])(.+)$ ]]; then
    arg="${BASH_REMATCH[1]}"
    args=( "-${BASH_REMATCH[2]}" "${args[@]}" )
  fi
}

###### Helpers ######

guardTput() {
  if [[ -n "$color" ]]; then tput "$@"; fi
}

dieUsage() {
  echo >&2 "$usage"
  exit 0
}

die() {
  if [[ -n "$1" ]]; then echo >&2 "$1"; fi
  exit 1
}

###### Run the Program ######

args=("$@")
main
