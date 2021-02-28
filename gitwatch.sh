#!/usr/bin/env bash

# gitwatch - watch file or directory and git commit all changes as they happen

# XXX: Add support for multiple watch directories
# XXX: Can we use git -C instead of changing to the directory ourselves?
# XXX: Create man page
# XXX: Add bash coverage
#      github actions:
#      https://about.codecov.io/blog/how-to-get-coverage-metrics-for-bash-scripts/

# Copyright (C) 2013-2018  Patrick Lehner
#   with modifications and contributions by:
#   - Matthew McGowan
#   - Dominik D. Geyer
#   - Phil Thompson
#   - Dave Musicant

#############################################################################
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#.
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#.
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
#.
#   Idea and original code taken from http://stackoverflow.com/a/965274
#       original work by Lester Buck
#       (but heavily modified by now)
#.
#   Requires the command 'inotifywait' to be available, which is part of the
#   inotify-tools (See https://github.com/rvoicilas/inotify-tools ), and
#   (obviously) git.
#.
#   Will check the availability of both commands using the `which` command and
#   will abort if either command (or `which`) is not found.

#   The above is incorrect, the 'hash' command is now used to check for the
#   existence of executables.

#############################################################################
# Probably copyrighted through till 2021 PatrickLehner
#.
# Alan Young stole this code and made it his own!
#.
# I refactored this using the mantra 'die early, die often'. I also added
# separator lines and otherwise made the formatting fit my preferences.
#.
#############################################################################

#-----------------------------------------------------------------------------
# Setup
#.
# Allow environment variables to override defaults, then allow command line
# arguments to override environment settings.

# XXX: Document these allowed environment variables
# GW_COMMITMSG
# GW_DATE_FMT
# GW_EVENTS
# GW_GIT_BIN
# GW_GIT_BRANCH
# GW_GIT_DIR
# GW_INW_BIN
# GW_REMOTE
# GW_RL_BIN

COMMITMSG="${GW_COMMITMSG:-Scripted auto-commit on change (%d) by gitwatch.sh}"
DATE_FMT="${GW_DATE_FMT:-+%Y-%m-%d %H:%M:%S}"

LISTCHANGES=-1
LISTCHANGES_COLOR="--color=always"
SLEEP_PID=
SLEEP_TIME=2
UNAME="$(uname)"

#############################################################################
# Functions

#-----------------------------------------------------------------------------
# print all arguments to stderr

stderr() { echo "$@" >&2; }

#-----------------------------------------------------------------------------
# Tests for the availability of a command

is_command() { hash "$1" 2> /dev/null; }

#-----------------------------------------------------------------------------
# clean up at end of program, killing the remaining sleep process if it still
# exists

cleanup() {
  [[ -n $SLEEP_PID ]] \
    && kill -0 "$SLEEP_PID" &> /dev/null \
    && kill "$SLEEP_PID" &> /dev/null

  exit 0
}

trap "cleanup" EXIT # make sure the timeout is killed when exiting script

#-----------------------------------------------------------------------------
# Print a message about how to use this script

shelp() {
  cat << EOH | ${PAGER:-less}
gitwatch - watch file or directory and git commit all changes as they happen

Usage:
${0##*/} [-s <secs>] [-d <fmt>] [-r <remote> [-b <branch>]]
         [-m <msg>] [-l|-L <lines>] <target>

Where <target> is the file or folder which should be watched. The target needs
to be in a Git repository, or in the case of a folder, it may also be the top
folder of the repo.

 -s <secs>        After detecting a change to the watched file or directory,
                  wait <secs> seconds until committing, to allow for more
                  write actions of the same batch to finish; default is 2sec
 -d <fmt>         The format string used for the timestamp in the commit
                  message; see 'man date' for details
                  (default is '$DATE_FMT')
 -r <remote>      If given and non-empty, a 'git push' to the given <remote>
                  is done after every commit; default is empty, i.e. no push
 -b <branch>      The branch which should be pushed automatically;
                  - if not given, the push command used is 'git push
                    <remote>', thus doing a default push (see git man pages
                    for details)
                  - if given and repo is in a detached HEAD state (at launch)
                    then the command used is 'git push <remote> <branch>'
                  - if given and repo is NOT in a detached HEAD state (at
                    launch) then the command used is 'git push <remote>
                    <current branch>:<branch>' where <current branch> is the
                    target of HEAD (at launch)
                  - if no remote was defined with -r, this option has no
                    effect
 -g <path>        Location of the .git directory, if stored elsewhere in
                  a remote location. This specifies the --git-dir parameter
 -l <lines>       Log the actual changes made in this commit, up to a given
                  number of lines, or all lines if 0 is given
 -L <lines>       Same as -l but without colored formatting
 -m <msg>         The commit message used for each commit; all occurrences of
                  %d in the string will be replaced by the formatted date/time
                  (unless the <fmt> specified by -d is empty, in which case %d
                  is replaced by an empty string); the default message is:
                  "Scripted auto-commit on change (%d) by gitwatch.sh"
 -e <events>      Events passed to inotifywait to watch (useful when using
                  inotify-win, e.g. -e modify,delete,move)
                  (defaults to '$EVENTS')
                  (currently ignored on Mac, which only uses default values)

As indicated, several conditions are only checked once at launch of the
script. You can make changes to the repo state and configurations even while
the script is running, but that may lead to undefined and unpredictable (even
destructive) behavior!  It is therefore recommended to terminate the script
before changing the repo's config and restarting it afterwards.

By default, gitwatch tries to use the binaries "git", "inotifywait", and
"readline", expecting to find them in the PATH (it uses 'which' to check this
and will abort with an error if they cannot be found). If you want to use
binaries that are named differently and/or located outside of your PATH, you
can define replacements in the environment variables GW_GIT_BIN, GW_INW_BIN,
and GW_RL_BIN for git, inotifywait, and readline, respectively.

Note: Whichever of -l and -L appear *LAST* in the parameter list will take
      precedence.
EOH

  exit 1
}

#-----------------------------------------------------------------------------
# Expand the path to the target to absolute path
# XXX: Use -e instead of -f and handle no such file/directory that way.

expand_path() {
  local path="$1"
  local expanded=

  expanded=$($RL -f "$path") || {
    echo "Seems like your readlink doesn't support '-f'. Running without."
    [[ $UNAME == 'Darwin' ]] && echo "Please 'brew install coreutils'."
    expanded=$($RL "$path")
  }

  printf '%s' "$expanded"
}

#-----------------------------------------------------------------------------
# Set TARGETDIR, inotifywait and git arguments

set_arguments() {
  local watch="$1"
  local IN
  IN="$(expand_path "$watch")"

  #---------------------------------------------------------------------------
  if [ -d "$IN" ]; then # if the target is a directory
    TARGETDIR="${IN%/}"

    # XXX: Original behavior if TARGETDIR is empty (IN resolves to /). I'm
    # defaulting to dying.

    [[ -z $TARGETDIR ]] && {
      stderr "Not watching entire file system. $WATCH resolves to '/'."
      # XXX: Document these exit values so this makes more sense
      exit 11
    }

    # construct inotifywait-commandline
    if [[ $UNAME == 'Darwin' ]]; then
      # still need to fix EVENTS since it wants them listed one-by-one
      INW_ARGS=('--recursive' "$EVENTS" '-E' '--exclude' "'(\.git/|\.git$)'" "'$TARGETDIR'")

    else
      INW_ARGS=('-qmr' '-e' "$EVENTS" '--exclude' "'(\.git/|\.git$)'" "'$TARGETDIR'")
    fi

    GIT_ADD_ARGS='--all .' # add "." (CWD) recursively to index
    # XXX: Was this '-a' removed by accident? or is this comment not needed
    #      anymore?
    GIT_COMMIT_ARGS='' # add -a switch to "commit" call just to be sure

  #---------------------------------------------------------------------------
  elif [ -f "$IN" ]; then # if the target is a single file
    TARGETDIR="${IN%/*}"

    # construct inotifywait-commandline
    if [[ $UNAME == 'Darwin' ]]; then
      INW_ARGS=("$EVENTS" "$IN")
    else
      INW_ARGS=('-qm' '-e' "$EVENTS" "$IN")
    fi

    GIT_ADD_ARGS="$IN" # add only the selected file to index
    GIT_COMMIT_ARGS='' # no need to add anything more to "commit" call

  #---------------------------------------------------------------------------
  else
    stderr "Error: The target is neither a regular file nor a directory."
    exit 3
  fi

  #---------------------------------------------------------------------------
  # If GW_GIT_DIR is set, verify that it is a directory and set git command
  # XXX: Add validation that it is actually a .git dir.

  [[ -z $GIT_DIR ]] && GIT_DIR="${GW_GIT_DIR:-}"

  if [[ -n $GIT_DIR ]]; then
    if [[ ! -d $GIT_DIR ]]; then
      stderr ".git location is not a directory: $GIT_DIR"
      exit 4
    fi

    [[ -n $GIT_DIR ]] \
      && GIT="$GIT --no-pager --work-tree $TARGETDIR --git-dir $GIT_DIR"
  fi

  #---------------------------------------------------------------------------
  # CD into target directory

  cd "$TARGETDIR" || {
    stderr "Error: Can't change directory to '$TARGETDIR'."
    exit 5
  }
}

#-----------------------------------------------------------------------------
# A function to reduce git diff output to the actual changed content, and
# insert file line numbers.  Based on
# "https://stackoverflow.com/a/12179492/199142" by John Mellor

diff-lines() {
  local path=
  local line=
  local previous_path=

  while read -r; do
    esc=$'\033'

    if [[ $REPLY =~ ---\ (a/)?([^[:blank:]$esc]+).* ]]; then
      previous_path=${BASH_REMATCH[2]}
      continue

    elif [[ $REPLY =~ \+\+\+\ (b/)?([^[:blank:]$esc]+).* ]]; then
      path=${BASH_REMATCH[2]}

    elif [[ $REPLY =~ @@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,[0-9]+)?\ @@.* ]]; then
      line=${BASH_REMATCH[2]}

    elif [[ $REPLY =~ ^($esc\[[0-9;]+m)*([\ +-]) ]]; then
      REPLY=${REPLY:0:150} # limit the line width, so it fits in a single line in most git log outputs

      if [[ $path == "/dev/null" ]]; then
        echo "File $previous_path deleted or moved."
        continue

      else
        echo "$path:$line: $REPLY"
      fi

      if [[ ${BASH_REMATCH[2]} != - ]]; then
        ((line++))
      fi
    fi
  done
}

#-----------------------------------------------------------------------------
# XXX: Document me!!!

push_cmd() {
  local push

  [[ -z $REMOTE ]] && REMOTE="${GW_REMOTE:-}"

  if [[ -n $REMOTE ]]; then # are we pushing to a remote?
    [[ -z $BRANCH ]] && BRANCH="${GW_GIT_BRANCH:-}"

    if [[ -z $BRANCH ]]; then  # Do we have a branch set to push to ?
      push="$GIT push $REMOTE" # Branch not set, push to remote without a branch

    else
      # check if we are on a detached HEAD
      if HEADREF=$($GIT symbolic-ref HEAD 2> /dev/null); then # HEAD is not detached
        push="$GIT push $REMOTE ${HEADREF#refs/heads/}:$BRANCH"

      else # HEAD is detached
        push="$GIT push $REMOTE $BRANCH"
      fi
    fi
  fi

  printf '%s' "$push"
}

###############################################################################
# Sanity checks

#-----------------------------------------------------------------------------
# If custom bin names are given for git, inotifywait, or readlink, use those;
# otherwise fall back to "git", "inotifywait", and "readlink"

GIT="${GW_GIT_BIN:-git}"
RL="${GW_RL_BIN:-readlink}"
INW="${GW_INW_BIN:-inotifywait}"

# if Mac, change some settings
if [[ $UNAME == 'Darwin' ]]; then
  [[ -z $GW_INW_BIN ]] && INW="fswatch"
  [[ -z $GW_RL_BIN ]] && is_command 'greadlink' && RL='greadlink'

  # default events specified via a mask, see
  # https://emcrisostomo.github.io/fswatch/doc/1.14.0/fswatch.html/Invoking-fswatch.html#Numeric-Event-Flags
  # default of 414 = MovedTo + MovedFrom + Renamed + Removed + Updated + Created
  #                = 256 + 128+ 16 + 8 + 4 + 2
  # XXX: The help is incorrect, EVENT is *not* ignored by default for mac. Fix.
  EVENTS="${GW_EVENTS:---event=414}"

else
  EVENTS="${GW_EVENTS:-close_write,move,move_self,delete,create,modify}"
fi

# Check availability of selected binaries and die if not met
for cmd in "$GIT" "$INW" "$RL"; do
  is_command "$cmd" || {
    stderr "Error: Required command '$cmd' not found."
    exit 2
  }
done
unset cmd

###############################################################################
# Process command line options

while getopts b:d:h:g:L:l:m:p:r:s:e: option; do
  case "$option" in
    b) BRANCH=${OPTARG} ;;
    d) DATE_FMT=${OPTARG} ;;
    e) EVENTS=${OPTARG} ;;
    g) GIT_DIR=${OPTARG} ;;
    h) shelp ;;
    l) LISTCHANGES=${OPTARG} ;;
    m) COMMITMSG=${OPTARG} ;;
    p | r) REMOTE=${OPTARG} ;;
    s) SLEEP_TIME=${OPTARG} ;;

    L)
      LISTCHANGES=${OPTARG}
      LISTCHANGES_COLOR=""
      ;;

    *)
      stderr "Error: Option '${option}' does not exist."
      shelp
      ;;
  esac
done

# Shift the input arguments, so that the input file (last arg) is $1 in the
# code below

shift $((OPTIND - 1))

# If no command line arguments are left (that's bad; no target was passed, or
# too many arguments were passed) print usage help and exit

WATCH="$1"
[[ -z $WATCH ]] && WATCH="${WATCH:-$GW_WATCH}"
[[ -z $WATCH ]] && shelp

###############################################################################

set_arguments "$WATCH"

#-----------------------------------------------------------------------------
# Check if commit message needs any formatting (date splicing)

if ! grep "%d" > /dev/null <<< "$COMMITMSG"; then # if commitmsg didn't contain %d, grep returns non-zero
  DATE_FMT=""                                     # empty date format (will disable splicing in the main loop)
  FORMATTED_COMMITMSG="$COMMITMSG"                # save (unchanging) commit message
fi

###############################################################################

# main program loop: wait for changes and commit them
#   whenever inotifywait reports a change, we spawn a timer (sleep process) that gives the writing
#   process some time (in case there are a lot of changes or w/e); if there is already a timer
#   running when we receive an event, we kill it and start a new one; thus we only commit if there
#   have been no changes reported during a whole timeout period

# XXX: GAH! No! Bad dev for using eval! Fix!

eval "$INW" "${INW_ARGS[@]}" | while read -r line; do
  # is there already a timeout process running?
  if [[ -n $SLEEP_PID ]] && kill -0 "$SLEEP_PID" &> /dev/null; then
    # kill it and wait for completion
    kill "$SLEEP_PID" &> /dev/null || true
    wait "$SLEEP_PID" &> /dev/null || true
  fi

  # start timeout process
  (
    # wait some more seconds to give apps time to write out all changes
    sleep "$SLEEP_TIME"

    if [ -n "$DATE_FMT" ]; then
      # splice the formatted date-time into the commit message
      FORMATTED_COMMITMSG="${COMMITMSG/\%d/$(date "$DATE_FMT")}"
    fi

    if [[ $LISTCHANGES -ge 0 ]]; then # allow listing diffs in the commit log message, unless if there are too many lines changed
      DIFF_COMMITMSG="$($GIT diff -U0 "$LISTCHANGES_COLOR" | diff-lines)"
      LENGTH_DIFF_COMMITMSG=0

      if [[ $LISTCHANGES -ge 1 ]]; then
        LENGTH_DIFF_COMMITMSG=$(echo -n "$DIFF_COMMITMSG" | grep -c '^')
      fi

      if [[ $LENGTH_DIFF_COMMITMSG -le $LISTCHANGES ]]; then
        # Use git diff as the commit msg, unless if files were added or deleted but not modified
        if [ -n "$DIFF_COMMITMSG" ]; then
          FORMATTED_COMMITMSG="$DIFF_COMMITMSG"

        else
          FORMATTED_COMMITMSG="New files added: $($GIT status -s)"
        fi

      else
        FORMATTED_COMMITMSG=$($GIT diff --stat | grep '|')
      fi
    fi

#    # CD into target directory
#    # XXX: Why are we doing this if we've already done it above?
#    cd "$TARGETDIR" || {
#      stderr "Error: Can't change directory to '$TARGETDIR'."
#      exit 6
#    }

    STATUS=$($GIT status -s)

    if [ -n "$STATUS" ]; then # only commit if status shows tracked changes.
      # We want GIT_ADD_ARGS and GIT_COMMIT_ARGS to be word splitted
      # shellcheck disable=SC2086
      $GIT add $GIT_ADD_ARGS # add file(s) to index

      # shellcheck disable=SC2086
      $GIT commit $GIT_COMMIT_ARGS -m"$FORMATTED_COMMITMSG" # construct commit message and commit

      PUSH_CMD="$(push_cmd)"

      if [ -n "$PUSH_CMD" ]; then
        echo "Push command is $PUSH_CMD"
        # XXX: GAH! Again with the eval! No! Fix!
        eval "$PUSH_CMD"
      fi
    fi
  ) & # and send into background

  SLEEP_PID=$! # and remember its PID
done
