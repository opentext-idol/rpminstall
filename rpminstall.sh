#!/bin/env bash

trace="${TRACE:-0}"
debug="${DEBUG:-0}"
quiet="${SILENT:-0}"
pretend="${PRETEND:-0}"

FROM_CFENGINE="${INVOKED_FROM_CFENGINE:-}"
EXIT_CF_REPAIRED=0
EXIT_CF_FAILED=1
EXIT_CF_KEPT=2

tmp="${TMPDIR:-${TMP:-/tmp}}"
bak="${BACKUP:-${TMPDIR}}"

# N.B.: Many elements here imported from stdlib.sh (https://github.com/srcshelton/stdlib.sh)...

function die() {
	echo >&2 -e "FATAL: $@"
	doExit ${EXIT_CF_FAILED:-1}
} # die

function dbg() {
	(( quiet )) && return

	if (( debug )); then
		if (( ${#@} )); then
			echo -e "$@" | fold -sw ${COLUMNS:-70} | sed 's/^/DEBUG:   /g' >&2
		else
			cat - | fold -sw ${COLUMNS:-70} | sed 's/^/DEBUG:   /g' >&2
		fi
	fi
	return $(( ! debug ))
} # dbg

function warn() {
	(( quiet )) && return

	if (( ${#@} )); then
		echo -e "$@" | fold -sw ${COLUMNS:-70} | sed 's/^/WARNING: /g' >&2
	else
		cat - | fold -sw ${COLUMNS:-70} | sed 's/^/WARNING: /g' >&2
	fi
} # warn

function note() {
	(( quiet )) && return

	if (( ${#@} )); then
		echo -e "$@" | fold -sw ${COLUMNS:-70} | sed 's/^/NOTICE:  /g' >&2
	else
		cat - | fold -sw ${COLUMNS:-70} | sed 's/^/NOTICE:  /g' >&2
	fi
} # note

function output() {
	(( quiet )) && return

	if (( ${#@} )); then
		echo -e "$@" | fold -s
	else
		cat - | fold -s
	fi
} # output

function doExit() {
	local -i intendedExitCode=${1:-0}

	local -i actualExitCode=0
	
	# The message below will actually return the details of the calling
	# function and line-number, not 'doExit' and the line below!
	dbg "DEBUG: doExit called from $BASH_SOURCE - $FUNCNAME - $BASH_LINENO with return-code '$intendedExitCode'"
	
	[[ -n "$TMPDIR" && -d "$TMPDIR" ]] && (( ! debug )) && rm -r "$TMPDIR" 2>/dev/null
	
	case $intendedExitCode in
		0)
			[[ -n "${FROM_CFENGINE:-}" ]] && actualExitCode=${EXIT_CF_REPAIRED:-0} || actualExitCode=0
			;;
		1)
			[[ -n "${FROM_CFENGINE:-}" ]] && actualExitCode=${EXIT_CF_FAILED:-1} || actualExitCode=1
			;;
		2)
			[[ -n "${FROM_CFENGINE:-}" ]] && actualExitCode=${EXIT_CF_KEPT:-2} || actualExitCode=0
			;;
		*)
			echo >&2 -e "WARN: Invalid return-code '$intendedExitCode'"
			[[ -n "${FROM_CFENGINE:-}" ]] && actualExitCode=${EXIT_CF_FAILED:-1} || actualExitCode=1
			;;
	esac
	
	exit $actualExitCode
} # doExit

UPDATE_SCRIPT="${UPDATE_SCRIPT:-rpmlist.sh}"
LIST_UPDATES="$( readlink -e "$( type -pf "$UPDATE_SCRIPT" )" 2>/dev/null || readlink -f "$( type -pf "$UPDATE_SCRIPT" )" 2>/dev/null )"
RPM="$( readlink -e "$( type -pf rpm )" 2>/dev/null || readlink -f "$( type -pf rpm )" 2>/dev/null )"
RPM_PATTERN="%{n}-%{v}-%{r}.%{arch}\n"

unalias mv >/dev/null 2>&1
unalias rm >/dev/null 2>&1

HAVE_BASH_4=0
# Can we rely on $SHELL?
# As an alternative, this should work but is a bit scary...
if [[ -r "$0" ]]; then
	# Assume the our interpreter is bash
	INT="$( head -n 1 "$0" )"
	INT="$( sed 's|^#\! \?||' <<<"$INT" )"
	if [[ "${INT:0:4}" == "env " || "${INT:0:9}" == "/bin/env " || "${INT:0:13}" == "/usr/bin/env " ]]; then
		BASH="$( cut -d' ' -f 2 <<<"$INT" )"
	else
		BASH="$( cut -d' ' -f 1 <<<"$INT" )"
	fi
	BASH="$( readlink -e "$( type -pf "$BASH" )" )"
	if [[ -x "$BASH" ]]; then
		VERSION="$( "$BASH" --version 2>&1 | head -n 1 )" || die "Cannot determine version for interpreter '$BASH'"
		if grep -q " version " >/dev/null 2>&1 <<<"$VERSION"; then
			if ! grep -q " version [0-3]" >/dev/null 2>&1 <<<"$VERSION"; then
				HAVE_BASH_4=1
			fi
		else
			die "Cannot determine version for interpreter '$BASH' (from '$VERSION')"
		fi
	else
		die "Cannot execute interpreter '$INT'"
	fi
else
	die "Cannot locate this script (tried '$0')"
fi

# bash-4 associative array(/hash)
(( HAVE_BASH_4 )) && declare -A INITSCRIPTS

function cleanup() {
	#extern HAVE_BASH_4 restart TMPDIR INITSCRIPTS*

	local SCRIPT INIT

	# Restart services we've stopped on error...
	if (( HAVE_BASH_4 )); then
		for SCRIPT in ${!INITSCRIPTS[@]}; do
			for INIT in ${INITSCRIPTS[$SCRIPT]}; do
				if (( 1 == restart )) || [[ "$INIT" =~ sshd$ || "$INIT" =~ xinetd$ ]]; then
					(( quiet )) || echo -n "Restarting service '$INIT' ... "
					if "$INIT" restart >/dev/null 2>&1; then
						(( quiet )) || echo "done"
					else
						(( quiet )) || echo "failed"
					fi
				else
					(( quiet )) || echo -n "Starting service '$INIT' ... "
					if "$INIT" start >/dev/null 2>&1; then
						(( quiet )) || echo "done"
					else
						(( quiet )) || echo "failed"
					fi
				fi
			done
			unset INIT
		done
		unset SCRIPT
	fi
	[[ -n "$TMPDIR" && -d "$TMPDIR" ]] && (( ! debug )) && rm -r "$TMPDIR" 2>/dev/null
} # cleanup

function processpkg() {
	local PKG="$1"
	#extern restart RPATH TMPDIR RPM RTOOL tmp INITSCRIPTS*

	local NAME FILE DIR TMPFILE RC

	[[ -n "$PKG" && -n "$RPATH" && -d "$TMPDIR" && -x "$RPM" ]] || return 1

	[[ -e "$TMPDIR"/"$PKG" ]] && { dbg "Package '$PKG' already exists on local filesystem ($TMPDIR)" ; return 0 ; }

	TMPFILE="$( mktemp -t "$( basename "$0" ).XXXXXXXX" )" || die "mktemp failed: $1"

	# If we perform 'rsync rsync://${RPATH}/*/${PKG}* .' then rsync is
	# happy but may fetch the wrong package (theoretically...) - however if
	# we drop the trailing '*' then rsync complains about every
	# destination folder where the named file *doesn't* exist and returns
	# with error 23 - Partial Transfer.
	# We could go with the former solution, but I'd prefer to be more
	# specific...

	"$RTOOL" "rsync://${RPATH}/*/${PKG}" "$TMPDIR"/ 2>"$TMPFILE"
	RC=$?
	if (( RC != 0 && RC != 23 )) || ! [[ -e "$TMPDIR"/"$PKG" ]]; then
		# This is only a rough check, as small volumes or large
		# packages may run out of space even if not 100% full...
		df "$TMPDIR" | grep -q '100%' >/dev/null 2>&1 && die "Filesystem containing '$TMPDIR' has run out of space! "

		warn "Package copy failed for '$PKG':"
		cat "$TMPFILE" | warn
		rm "$TMPFILE" 2>/dev/null
		return 1
	fi
	rm "$TMPFILE" 2>/dev/null
	unset TMPFILE

	if ! (( pretend )); then
		NAME="$( sed 's/-[0-9].*$//' <<<"$PKG" )"
		if (( HAVE_BASH_4 )); then
			if [[ "$NAME" =~ ^initscripts ]]; then
				dbg "Not considering services from package '$NAME'"
			else
				for FILE in $( "$RPM" -ql "$NAME" | grep '/init\.d/' ); do
					if [[ -x "$FILE" ]]; then
						if [[ "$FILE" =~ sshd$ || "$FILE" =~ xinetd$ ]]; then
							INITSCRIPTS["$PKG"]="${INITSCRIPTS["$PKG"]} $FILE"
							dbg "Not stopping service '$FILE'"
						elif [[ "$FILE" =~ krb524$ ]]; then
							dbg "Not interacting with broken service '$FILE'"
						elif [[ "$FILE" =~ microcode_ctl$ ]]; then
							dbg "Not interacting with boot-time service '$FILE'"
						elif "$FILE" status >/dev/null 2>&1; then
							INITSCRIPTS["$PKG"]="${INITSCRIPTS["$PKG"]} $FILE"
							if (( 1 == restart )); then
								(( quiet )) || echo "Flagging service '$FILE' for post-upgrade restart"
							else
								(( quiet )) || echo -n "Stopping service '$FILE' ... "
								if "$FILE" stop >/dev/null 2>&1; then
									(( quiet )) || echo "done"
								else
									(( quiet )) || echo "failed"
								fi
							fi
						else
							dbg "Not stopping non-running service '$FILE'"
						fi
					fi
				done
			fi
		fi
		for FILE in $( "$RPM" -ql "$NAME" | grep '/boot/' ) $( "$RPM" -ql "$NAME" | grep '/lib/modules/' ); do
			if [[ -e "$FILE" ]]; then
				DIR="$( dirname "$FILE" )"

				mkdir -p "$bak"/"$DIR" 2>/dev/null || continue
				(( debug )) && echo -n "$( sed 's|//\+|/|g' <<<"Backing up '$FILE' to '$bak/$FILE' ... " )"
				local err
				err="$( /bin/cp -a "$FILE" "$bak"/"$FILE" 2>&1 )" && dbg "done" || dbg "cp failed: $? '$err'"

				unset DIR
			fi
		done
	fi

	return 0
} # processpkg

function addpkg() {
	local PKG="$1"
	local ARCH="${2:-${SYSARCH}}"
	#extern REPO LIST_UPDATES RDIR TMPDIR quickstart

	local added checked NEWPKG files newfiles

	[[ -n "$PKG" && -x "$LIST_UPDATES" && -d "$TMPDIR" ]] || return 2

	if [[ -e "$TMPDIR"/"$PKG"*.${ARCH}.rpm ]]; then
		dbg "Package '$PKG'($ARCH) already exists on local filesystem ($TMPDIR)"
		return 0
	else
		dbg "Attempting to retrieve new package '$PKG'($ARCH) ..."
	fi

	added=1
	checked=""
	for ARCH in "$ARCH" "noarch" "${SYSARCH}"; do
		[[ -n "$ARCH" ]] || continue

		grep -qw "$ARCH" >/dev/null 2>&1 <<<"$checked" && continue
		checked="$checked $ARCH"

		for NEWPKG in $( TRACE=$trace DEBUG=$debug "$LIST_UPDATES" --location="${RDIR}" --host="${REPO}" --arch="$ARCH" --pkg="$PKG" $quickstart 2>/dev/null | grep ^UPGRADE | sort | uniq | cut -d' ' -f 2- ); do
			processpkg "$NEWPKG" || die "Failed to retrieve package '$NEWPKG' for architecture '$ARCH'"
			added=0
		done
		(( 0 == added )) && break
	done

	(( 0 == added )) || dbg "Package '$PKG' could not be retrieved"

	echo "$ARCH"
	return $added
} # addpkg

declare help=0
declare restart=2
declare param=""
declare quickstart=""
# We're not using getopt(-long), as we want to pass unrecognised short- and
# long- options to $LIST_UPDATES - and getopt expects to eat all option
# arguments
while [[ -n "${1:-}" ]]; do
	PARAM="${1}"
	case "$PARAM" in
		-c|-C|--location)
			# NB: This can also be specified by setting 'PKGDIR' in
			#     the environment.
			shift
			RDIR="$1"
			;;
		-d|--debug)
			debug=1
			;;
		-h|--help)
			help=1
			;;
		--host)
			shift
			HOST="$1"
			;;
		--quiet)
			quiet=1
			;;
		-q|--quickstart)
			shift
			quickstart="--quickstart $1"
			;;
		-r|--restart)
			case $restart in
				2)
					restart=1
					;;
				1)
					dbg "Multiple '-r' options specified"
					;;
				0)
					die "'-r' and '-s' options are mutually-exclusive"
					;;
			esac
			;;
		-s|--stop)
			case $restart in
				2)
					restart=0
					;;
				1)
					die "'-r' and '-s' options are mutually-exclusive"
					;;
				0)
					dbg "Multiple '-s' options specified"
					;;
			esac
			;;
		-t|--dry-run|--pretend)
			pretend=1
			;;
		-x|--trace)
			trace=1
			;;
		*)
			param="$param $PARAM"
			;;
	esac
	shift
done
(( 2 == restart )) && restart=0
export restart

# We need to determine these locations before printing our help text...
HOST="${HOST:-rpmrepo}"
if echo "${HOST}" | grep -Eq '^(([0-9]|[1-9][0-9]|[1-2][0-9][0-9])\.){3}([0-9]|[1-9][0-9]|[1-2][0-9][0-9])$' >/dev/null 2>&1; then
	REPO="${HOST}"
else
	if type -pf "getent" >/dev/null 2>&1; then
		REPO="$( getent hosts "${HOST}" | tr -s [:space:] | cut -d' ' -f 1 )"
	else
		REPO="$( host "${HOST}" | grep " has address " | sed 's/^.* address //' )"
	fi
fi

RTOOL="$( readlink -e "$( type -pf rsync )" 2>/dev/null || readlink -f "$( type -pf rsync )" 2>/dev/null )"
if [[ -n "${PKGDIR}" ]]; then
	RDIR="${PKGDIR}"
else
	# Old-style layout with all packaages in a single directory below
	# centos-updates...
	#RDIR="${RDIR:-vendor/centos-updates}"

	# New-style layout, with content in /srv (and rsync with a repo rooted
	# here), and data in /srv/vendor/centos/os/
	RDIR="${RDIR:-vendor/*}"
fi
RARGS=""
RPATH="${REPO}/${RDIR}"
RDEST="rsync://${RPATH}/*/*.rpm" # => rsync://rpmrepo/vendor/*/*/*.rpm

if (( help )); then
	echo "$( basename "$0" ) - Evaluate available RPM packages, and install with"
	echo "                       inferred dependencies."
	echo
	echo "Options:"
	echo " -h | --help                : Show this help"
	echo " -d | --debug               : Output brief debug statements"
	echo " -c | --location            : Override path to RPM repo"
	echo "      --host                : Override repo host"
	echo " -q | --quickstart          : Cache package list in file"
	echo " -r | --restart             : Only restart services post-upgrade"
	echo " -s | --stop                : Stop services before upgrading"
	echo " -t | --pretend | --dry-run : Don't really install anything"
	echo " -x | --trace               : Output (very) verbose debug data"
	echo
	echo "Environment variables:"
	echo " DEBUG  - see --debug"
	echo " TRACE  - see --trace"
	echo " TMPDIR - Temporary directory used during package retrieval"
	echo " BACKUP - Storage location for archive of replaced boot files"
	echo
	echo "Embedded settings:"
	echo "File repository             : $HOST (${REPO:-<unknown>})"
	echo "File path                   : ${REPO:-<unknown>}:/$RDIR"
	echo "Script path                 : ${LIST_UPDATES:-<not found>}"
	if [[ -x "$LIST_UPDATES" ]]; then
		echo
		echo "Script options:"
		"$LIST_UPDATES" --help
	fi
	doExit ${EXIT_CF_FAILED:-1}
fi

(( trace )) && set -o xtrace

[[ -n "$REPO" ]] || die "Cannot determine '$HOST' server"

[[ -x "$RTOOL" ]] || die "Failed to find rsync"
if ! "$RTOOL" --version | grep -Eq "version [0-2]" >/dev/null 2>&1; then
	# rsync-3.x feature
	RARGS="--list-only"
fi

[[ -x "$RPM" && -x "$RTOOL" ]] || die "Failed to find OS utilities"
[[ -x "$LIST_UPDATES" ]] || die "Cannot find executable updates script '$UPDATE_SCRIPT'"

ping -c 1 "$REPO" >/dev/null 2>&1 || die "Cannot resolve $HOST (read '$REPO')"

trap cleanup INT QUIT TERM EXIT
otmp="$tmp"
tmp="$( readlink -m "$otmp" 2>/dev/null )" || die "Cannot canonicalise temporary directory path '$otmp'"
unset otmp
mkdir -p "$tmp" 2>/dev/null || die "Cannot access/create temporary directory '$tmp' - check \$TMPDIR"
TMPDIR="$( mktemp -dt "$( basename "$0" ).XXXXXXXX" )" || die "mktemp failed: $!"

SYSARCH="$( uname -i )"
[[ -n "$SYSARCH" && "$SYSARCH" != "unknown" ]] || die "Cannot identify system architecture"

# Ensure that we don't get stuck if installing filesystem-*.rpm
# https://bugzilla.redhat.com/show_bug.cgi?id=90941
mkdir -p /etc/rpm >/dev/null 2>&1
if [[ -s /etc/rpm/macros ]]; then
	# Why are Red Hat's tools so broken?? sed groks '\s' but grep doesn't :(
	if grep -q '^[[:space:]]*%_netsharedpath[[:space:]]' /etc/rpm/macros >/dev/null 2>&1; then
		NSP="$( grep '^[[:space:]]*%_netsharedpath[[:space:]]\+.*$' /etc/rpm/macros | sed 's/\s\+$//' )"
		changed=0
		for DIR in /dev /proc /sys; do
			grep -Eq "[[:space:]:]${DIR}([:[:space:]]|$)" <<<"$NSP" || { NSP="${NSP}:${DIR}" ; changed=1 ; }
		done
		unset DIR
		(( changed )) && { sed -i "s|^\s*%_netsharedpath\s\+.*$|${NSP}|" /etc/rpm/macros || die "Failed to update '/etc/rpm/macros'" ; }
		unset changed NSP
	else
		echo "%_netsharedpath /dev:/proc:/sys" >> /etc/rpm/macros || die "Failed to update '/etc/rpm/macros'"
	fi
else
	echo "%_netsharedpath /dev:/proc:/sys" > /etc/rpm/macros || die "Failed to update '/etc/rpm/macros'"
fi

output "Building upgrade package list ..."
count=0
TMPFILE="$TMPDIR/$( basename "$LIST_UPDATES" ).out"
eval "TRACE=$trace DEBUG=$debug "$LIST_UPDATES" --location="${RDIR}" --host="${REPO}" $quickstart $param 2>/dev/null | grep ^UPGRADE | sort | uniq | cut -d' ' -f 2- > "$TMPFILE""
[[ 0 == "${PIPESTATUS[0]}" ]] || die "Unable to locate package '$PKG'"
for PKG in $( cat "$TMPFILE" ); do
	processpkg "$PKG" || {
		warn "Failed to process package '$PKG'"
		sed -i "/$PKG/d" "$TMPFILE" 2>/dev/null
	}
	(( count++ ))
done # || die "$LIST_UPDATES failed: $?"
/bin/rm "$TMPFILE" 2>/dev/null
unset TMPFILE

# This probably cannot ever happen... it would require that we've received a
# valid package list with UPGRADE items listed, but have then processed none
# of them.
if ! (( count )); then
	note "No packages in need of upgrade - exiting"
	doExit ${EXIT_CF_KEPT:-2}
fi

output "Successfully processed $count packages"

if (( HAVE_BASH_4 && !( pretend ) )); then
	if (( 0 != ${#INITSCRIPTS[@]} )); then
		note "Packages with scripts which require restarting:"
		note "${!INITSCRIPTS[@]}"
	fi
fi

# Note regarding 'tries' and 'MAXTRIES':
# The original implementation initialised tries=MAXTRIES and decremented its
# value with each iteration.  If tries reached zero without having resolved
# all dependencies, then the process was judged to have failed.
# This is obviously a bad idea, since it means that failing installations
# require at least MAXTRIES iterations, but also breaks with legitimate long
# dependency chains.
# As a result, the logic now tests to see whether the failure list has
# quiesced, and will stop immediately at this point.
# However, this still leaves a test of whether tries is zero at the heart of
# the algorithm.  This value is altered when 'rpm -Uvh ...' succeeds, when
# all packages have been removed, or a steady-state is attained (indicating
# failure).  This does not tally exactly with the repeat variable, which has
# a wider scope.  Possibly the only change required is renaming tries to a
# more representative name.
#MAXTRIES=5
#tries=$MAXTRIES
# Update:
# 'repeat' renamed to 'popstate' (which is when it's used);
# 'tries' renamed to 'repeat' (as above).
# Update 20140204:
# 'popstate' removed entirely!  The logic it was invoking was actually in the
#  wrong place, and wouldn't have worked if it weren't ;)  The corrected logic
#  is now executed at the very top of the (aptly-named) 'repeat' loop, and no
#  further outer loop is required for state-popping.

repeat=1

output "Attempting to resolve dependencies ..."
success=0
noneleft=0
added=0
lastsum=""
currentsum=""

while (( repeat )); do
	[[ -d "$TMPDIR"	]] || die "Working directory '$TMPDIR' removed - aborting"
	
	if "$RPM" --test -Uv "$TMPDIR"/*.rpm >"$TMPDIR"/results.out 2>&1 && currentsum="$( md5sum "$TMPDIR"/results.out 2>/dev/null )"; then
		if [[ -d "$TMPDIR"/saved ]]; then
			# Child state is in TMPDIR
			# Original parent state is in TMPDIR/saved, but
			# should now resolve (hopefully... we may need
			# to clear the parent and restart with only the
			# child state if we're unlucky...)
			warn "Child state resolved: reverting to parent state"
			mv "$TMPDIR"/saved/*.rpm "$TMPDIR"/ || die "State package move failed: $?"
			rmdir "$TMPDIR"/saved || die "State removal failed: $?"
			lastsum=""
			added=0
		else
			success=1
			repeat=0
		fi

	elif (( added )) && [[ "$currentsum" == "$lastsum" ]]; then
		if grep -q "filesystem$" "$TMPDIR"/results.out >/dev/null 2>&1; then
			warn "Filesystem does not have enough free space! "
			repeat=0
		else
			warn "No change in package state, aborting"
			(( debug )) && echo
			dbg "Steady-state was:"
			cat "$TMPDIR"/results.out 2>/dev/null | dbg
			repeat=0
		fi

	else
		added=1
		lastsum="$currentsum"

		(( debug )) && cat "$TMPDIR"/results.out 2>/dev/null | grep -v "^warning: "

		# "is needed by (installed)" is a nasty case to try to handle automatically,
		# since it only occurs when dependencies are already broken - so we'll exclude
		# that case for now...
		ARCH=""
		grep -F "(installed)" "$TMPDIR"/results.out 2>/dev/null | grep -vF " is needed by (installed)" | cut -d')' -f 2 | sed 's/^ // ; s/$/.rpm/' > "$TMPDIR"/results.list && while read PKG; do
			dbg "Adding RPM dependency '$PKG' ..."
			ARCH="$( grep -oE ".(i[3-6]86|x86_64|noarch).rpm$" <<<"$PKG" | cut -d'.' -f 2 )"
			processpkg "$PKG" || die "Failed to add package"
		done < "$TMPDIR"/results.list
		ARCH="${ARCH:-$SYSARCH}"
		grep -F "(installed)" "$TMPDIR"/results.out 2>/dev/null | grep -vF " is needed by (installed)" | sed 's/^ \+//' | cut -d' ' -f 1,3 | sed "s/ /-/ ; s/$/.$ARCH.rpm/" > "$TMPDIR"/results.list && while read PKG; do
			dbg "Adding dependency '$PKG' ..."
			processpkg "$PKG" || die "Failed to add package"
		done < "$TMPDIR"/results.list

		# ... although if we try to upgrade the *installed* package, there's a chance
		# it'll pull-in the one which fails and resolve the problem.
		#grep -F "(installed)" "$TMPDIR"/results.out | grep -F " is needed by (installed)" | sed 's/^ \+//' | cut -d' ' -f 1,3 | sed "s/ [0-9]\+:/ / ; s/ /-/ ; s/$/.$ARCH.rpm/" > "$TMPDIR"/results.list && while read PKG; do
			#dbg "Adding package '$PKG' to attempt to resolve broken dependency ..."
			#processpkg "$PKG" || die "Failed to add package"
		#done < "$TMPDIR"/results.list
		rm "$TMPDIR"/results.list >/dev/null 2>&1
		grep -F "(installed)" "$TMPDIR"/results.out 2>/dev/null | grep -F " is needed by (installed)" | while read ENTRY; do
			# Assume format of:
			#  libxml2 = 2.5.4 is needed by (installed) libxml2-devel-2.5.4-1
			# ... where the item after the closing bracket is the name of the
			# problematic RPM, which we can then try to re-install.
			PKG="$( echo "$ENTRY" | cut -d')' -f 2 | sed 's/^ // ; s/$/.rpm/' )"
			if echo "$PKG" | grep -Eq '^\((32|64)bit.rpm' >/dev/null 2>&1; then
				# Either RPMforge packages or an older version of RPM use a different format :(
				# We are seeing the format:
				#  libfuse.so.2()(64bit) is needed by (installed) fuse-encfs-1.4.1-1.el5.rf.x86_64
				# ... in which case should we be trying to re-install the package, or drop the
				# library through to the code below?
				PKG="$( echo "$ENTRY" | sed 's/^.* (installed) // ; s/$/.rpm/' )"
			fi
			echo "$PKG" >> "$TMPDIR"/results.list
		done
		#grep -F "(installed)" "$TMPDIR"/results.out | grep -F " is needed by (installed)" | cut -d')' -f 2 | sed 's/^ // ; s/$/.rpm/' > "$TMPDIR"/results.list && while read PKG; do
		[[ -s "$TMPDIR"/results.list ]] && while read PKG; do
			ARCH="$( grep -oE ".(i[3-6]86|x86_64|noarch).rpm$" <<<"$PKG" | cut -d'.' -f 2 )"
			PKGNAME="$( sed 's/-[0-9].*$//' <<<"$PKG" )"
			if [[ "$PKGNAME" == "$PKG" && -d "$TMPDIR"/saved ]]; then
				#die "Only one level of saved state can be maintained"
				echo >&2 "FATAL: This system has broken dependencies, and the specified package(s)"
				echo >&2 "       cannot be reconciled against the existing packages."
				if ! (( quiet )); then
					echo >&2
					echo >&2 "Try removing the package $( "$RPM" -qa --qf "$RPM_PATTERN" | grep "$PKGNAME" ).rpm and retry this installation." | fold -s
					echo >&2 "Remember to ensure that this package is re-installed afterwards! "
				fi
				cleanup
				doExit ${EXIT_CF_FAILED:-1}
			elif [[ -d "$TMPDIR"/saved ]]; then
				# The contents of 'saved' from the original run are
				# (potentially) still good, but the RPMs in the current
				# session clearly didn't help - let's remove these but
				# keep the saved packages...
				rm "$TMPDIR"/*.rpm

				if ARCH="$( addpkg "$PKGNAME" "$ARCH" )"; then
					dbg "Successfully added package '$PKGNAME'($ARCH) to resolve child state"
					added=0
				else
					dbg "Unable to add package '$PKGNAME'($ARCH) to resolve child state"
				fi
			else # [[ ! -d "$TMPDIR"/saved ]]
				mkdir "$TMPDIR"/saved && mv "$TMPDIR"/*.rpm "$TMPDIR"/saved/ || {
					echo >&2 "FATAL: Could not create saved-state"
					cleanup
					doExit ${EXIT_CF_FAILED:-1}
				}
			fi
			warn "Clearing state and adding package '$PKG' to attempt to resolve broken dependency ..."
			processpkg "$PKG" || die "Failed to add package"
		done < "$TMPDIR"/results.list

		for PKG in $( grep "which is newer than .* is already installed$" "$TMPDIR"/results.out 2>/dev/null | sed -r 's/^[[:space:]]*//' | cut -d' ' -f 7 | sed 's/)$//' ); do
			note "Discounting existing package '$PKG' ..."
			if [[ -e "$TMPDIR"/"$PKG".rpm ]]; then
				rm "$TMPDIR"/"$PKG".rpm 2>/dev/null || die "Failed to remove package"
			else
				if ! (( quiet )); then
					echo "WARNING: Attempted to install non-existant installed"
					echo "         package '$TMPDIR/$PKG.rpm' (??)"
				fi
			fi
		done

		for PKG in $( grep "is already installed$" "$TMPDIR"/results.out 2>/dev/null | grep -v "which is newer than" | sed -r 's/^[[:space:]]*//' | cut -d' ' -f 2 ); do
			NAME="$( sed 's/-[0-9].*$//' <<<"$PKG" )"
			VERSION="$( sed -r 's/\.(i[3-6]86|x86_64|noarch)$//' <<<"$PKG" | sed "s/^$NAME-//" )"
			ARCH="$( sed -r 's/^.*\.(i[3-6]86|x86_64|noarch)$/\1/' <<<"$PKG" )"
			NEWVER="$( grep -E "replacing with $NAME [^ ]+ [0-9]+:$VERSION" "$TMPDIR"/results.out 2>/dev/null | cut -d' ' -f 5 | sed 's/^[0-9]\+://' )"
			if [[ -n "$NEWVER" ]]; then
				PKG="$NAME-$NEWVER.$ARCH"
				dbg "Discounting existing replaced package '$PKG' ..."
				if [[ -e "$TMPDIR"/"$PKG".rpm ]]; then
					rm "$TMPDIR"/"$PKG".rpm 2>/dev/null || die "Failed to remove replaced package"
				else
					if ! (( quiet )); then
						echo "WARNING: Attempted to install non-existant installed"
						echo "         package '$TMPDIR/$PKG.rpm' (??)"
					fi
				fi
			else
				note "Discounting existing package '$PKG' ..."
				if [[ -e "$TMPDIR"/"$PKG".rpm ]]; then
					rm "$TMPDIR"/"$PKG".rpm 2>/dev/null || die "Failed to remove package"
				else
					if ! (( quiet )); then
						echo "WARNING: rpm is reporting that a package which we aren't trying to install is"
						echo "         already installed."
						echo "         This is known to happen when the package version of an RPM archive does"
						echo "         not match the package file-name."
						echo "         To fix this issue, please follow these steps:"
						echo "           1) Locate the '$PKG.rpm' package;"
						echo "           2) Confirm that the real version of this package differs from the"
						echo "              filename with 'rpm -qpi $PKG.rpm';"
						echo "           3) Rename this file with the correct version number, as output by RPM"
						echo "              in the previous step;"
						echo "           4) Re-run this command ('$0 $@')."
						echo
					fi
					die "Failed to remove incorrectly-versioned package '$TMPDIR/$PKG.rpm'"
				fi
			fi
		done

		for PKG in $( grep -F "perl(" "$TMPDIR"/results.out 2>/dev/null | sed -r 's/^[[:space:]]*//' | cut -d' ' -f 1 | sed 's/(/-/ ; s/::/-/g ; s/)//' ); do
			dbg "Adding perl module '$PKG' ..."
			if addpkg "$PKG" >/dev/null; then
				dbg "Successfully added perl module '$PKG'"
				added=0
			else
				dbg "Failed to add perl module '$PKG'"
			fi
		done

		# Installation of new packages (or those force-installed with missing dependencies) below here...
		#
		# Formats:
		#  nscd is needed by nss_ldap-253-51.el5_9.1.x86_64
		#  glibc-common = 2.5-107.el5_9.5 is needed by glibc-2.5-107.el5_9.5.x86_64
		#  liblzma.so.0()(64bit) is needed by xz-devel-4.999.9-0.3.beta.20091007git.el5.x86_64
		grep -F " is needed by " "$TMPDIR"/results.out 2>/dev/null | sed 's/^ \+//' > "$TMPDIR"/results.list && while read LINE; do
			ITEM="$( cut -d' ' -f 1 <<<"$LINE" )"
			PKG="$( sed 's/([^)]*)//g ; s/\.so.*$//' <<<"$ITEM" )"
			OPKG="$PKG"

			ARCH="$( grep -oE ".(i[3-6]86|x86_64|noarch)$" <<<"$ITEM" | cut -d'.' -f 2 )"
			[[ -n "$ARCH" ]] || ARCH="$( grep -oEm 1 ".(i[3-6]86|x86_64|noarch)([.[:space:]]|$)" <<<"$LINE" | cut -d'.' -f 2 )"
			OARCH="$ARCH"

			# If glibc needs upgrading, then several other dependant pacakges must be specified at the same time.
			# Omitting any of these packages causes unresolvable dependencies to be reported between 32bit and 64bit package variants :(
			DEP="$( sed 's/ \+$//' <<<"$LINE" | sed 's/^.* //' )"
			DPKG="$( sed 's/-[0-9].*$//' <<<"$DEP" )"
			if [[ "$OARCH" == "x86_64" && "$DPKG" == "glibc" ]]; then
				for DPKG in glibc glibc-common; do
					if ARCH="$( addpkg "$DPKG" "x86_64" )"; then
						dbg "Successfully added package '$DPKG'($ARCH) as glibc dependency"
						added=0
					else
						dbg "Unable to add package '$DPKG'($ARCH) as glibc dependency"
					fi
				done
				for DPKG in glibc; do
					if ARCH="$( addpkg "$DPKG" "i686" )"; then
						dbg "Successfully added package '$DPKG'($ARCH) as glibc dependency"
						added=0
					else
						dbg "Unable to add package '$DPKG'($ARCH) as glibc dependency"
					fi
				done
			fi

			# (Fairly) Horrible lookup-list... I'm not sure of any better way to handle these inconsistencies :(
			case $PKG in
				libGL)			PKG="mesa-libGL" ;;
				libaprutil)		PKG="apr-util" ;;
				libasound)		PKG="alsa-lib" ;;
				libavahi-client)	PKG="avahi" ;;
				libavahi-common)	PKG="avahi" ;;
				libbz2)			PKG="bzip2-libs" ;;
				libext4fs)		PKG="e4fsprogs-libs" ;;
				libgif)			PKG="giflib" ;;
				libgnomevfs-2)		PKG="gnome-vfs2" ;;
				liblzma)		PKG="xz-libs" ;;
				libltdl)		PKG="libtool-ltdl" ;;
				libodbc)		PKG="unixODBC" ;;
				libodbcinst)		PKG="unixODBC" ;;
				libpq)			PKG="postgresql-libs" ;;
				libpython2.4)		PKG="python-libs" ;;
				libXmuu)		PKG="libXmu" ;;
				mkfontdir|mkfontscale)	PKG="xorg-x11-font-utils" ;;
				xfs)			PKG="xorg-x11-xfs" ;;
				libgdk-x11-*)		PKG="gdk-pixbuf" ;;
				libgdk_pixbuf-2.0)	PKG="gtk2-2" ;;
				libgdk-1.2)		PKG="gtk+" ;;
				libgtk-x11-2.0)		PKG="gtk2-2" ;;
				libgtk-1.2)		PKG="gtk+" ;;
				libORBit-2)		PKG="ORBit2-2" ;;
				libgconf-2)		PKG="GConf2-2" ;;
				libgconf-2)		PKG="GConf2-2" ;;
				libdns_sd)		PKG="avahi-compat-libdns_sd" ;;
				desktop-notification-daemon)	PKG="notification-daemon" ;;
				libXRes)		PKG="libXres" ;;
			esac
			(( debug )) && [[ "$PKG" != "$OPKG" ]] && note "Switched package '$OPKG' to '$PKG'"

			if ARCH="$( addpkg "$PKG" "$OARCH" )"; then
				dbg "Successfully added package '$PKG'($ARCH)"
				added=0
			else
				dbg "Addition of package '$PKG' failed - trying alternatives ..."
				case "$PKG" in
					lib*)
						dbg "Unresolvable package '$PKG' appears to be a library ..."
						for PKG in "${OPKG/lib}-lib" "${OPKG/lib}" "$( sed -r 's/(-[\.0-9]+)$// ; s/_/-/' <<<"${OPKG}" )" "$( sed -r 's/(-[\.0-9]+)$// ; s/(\.[\.0-9]+)$// ; s/_/-/' <<<"${OPKG}" )"; do
							dbg "... trying '$PKG'"
							if ARCH="$( addpkg "$PKG" "$OARCH" )"; then
								(( debug )) && [[ "$PKG" != "$OPKG" ]] && note "Switched package '$OPKG' to '$PKG'($ARCH) (library dependency) and successfully added"
								break
							fi
						done
						;;
					*/bin/*|*/sbin/*)
						dbg "Unresolvable package '$PKG' appears to be a binary ..."
						PKG="$( basename "$PKG" )"
						dbg "... trying '$PKG'"
						if ARCH="$( addpkg "$PKG" "$OARCH" )"; then
							(( debug )) && [[ "$PKG" != "$OPKG" ]] && note "Switched package '$OPKG' to '$PKG'($ARCH) (binary dependency) and successfully added"
						fi
						;;
					*/lib*/*)
						dbg "Unresolvable package '$PKG' appears to be a lib directory ..."
						PKG="$( basename "$PKG" | sed -r 's/^([^0-9]+)([0-9.]+)/\1-\2/' )"
						dbg "... trying '$PKG'"
						if ARCH="$( addpkg "$PKG" "$OARCH" )"; then
							(( debug )) && [[ "$PKG" != "$OPKG" ]] && note "Switched package '$OPKG' to '$PKG'($ARCH) (lib directory dependency) and successfully added"
						fi
						;;
					*)
						dbg "Package '$PKG' is not a library or binary dependency, taking no further action in this iteration"
						;;
				esac
			fi
		done < "$TMPDIR"/results.list

		/bin/rm "$TMPDIR"/results.list 2>/dev/null
	fi
	if [[ -z "$( ls -1 "$TMPDIR"/*.rpm 2>/dev/null )" ]]; then
		output "All candidate packages discounted, nothing to do.  Quitting."
		noneleft=1
		repeat=0
	fi
	(( debug )) || /bin/rm "$TMPDIR"/results.out 2>/dev/null
done

if (( success )); then
	if (( pretend )); then
		if "$RPM" -Uv --test "$TMPDIR"/*.rpm 2>/dev/null; then
			output "Installation dry-run succeeded for packages:"
			ls -1 "$TMPDIR"/*.rpm 2>/dev/null | sed "s|$TMPDIR/|	| ; s/\.rpm$//" | output
		else
			output "Install of packages from '${TMPDIR}' failed: $?"
		fi
	else
		output "Dependencies successfully determined"
		{ "$RPM" -Uv "$TMPDIR"/*.rpm 2>&1 && rm "$TMPDIR"/*.rpm 2>&1 || output "Install of packages from '${TMPDIR}' failed: $?" ; } | grep -v "^warning: " | sed -r 's/^([^P])/	\1/g'
	fi
else
	(( noneleft )) || echo >&2 "FATAL: Test install failed, aborting"
fi

# There's no point (re)starting services if we've not done anything...
(( pretend || restart && noneleft )) && {
	# Ensure that temporary directories are removed once we've finished with
	# them, even if we're not (re)starting services...
	[[ -n "$TMPDIR" && -d "$TMPDIR" ]] && (( ! debug )) && rm -r "$TMPDIR" 2>/dev/null
} || cleanup

(( HAVE_BASH_4 )) && unset INITSCRIPTS

trap - INT QUIT TERM EXIT

if ! (( pretend )); then
	if (( noneleft )); then
		note "No packages in need of upgrade - exiting"
		doExit ${EXIT_CF_KEPT:-2}
	elif (( success )); then
		if [[ -n "${FROM_CFENGINE:-}" ]] && ! (( quiet )); then
			echo "Upgrade complete - feel free to interrupt now with Ctrl+C"
			echo
			echo "Searching for outdated configuration files ..."
			find $( mount | grep "^/dev/" | cut -d' ' -f 3 ) -xdev -type f -name \*.rpmnew -or -name \*.rpmsave -print | sed 's/^/	/g'
		fi
	else
		(( quiet )) || echo >&2 "Upgrade failed - please see above (or re-execute with '-d' option) for further details"
		doExit ${EXIT_CF_FAILED:-1}
	fi
fi

doExit ${EXIT_CF_REPAIRED:-0}

