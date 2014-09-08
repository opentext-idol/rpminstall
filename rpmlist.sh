#!/bin/env bash

trace="${TRACE:-0}"
debug="${DEBUG:-0}"
compdebug="${COMPDEBUG:-0}"

FROM_CFENGINE="${INVOKED_FROM_CFENGINE:-}"
EXIT_CF_REPAIRED=0
EXIT_CF_FAILED=1
EXIT_CF_KEPT=2

function die() {
	echo >&2 "FATAL: $@"
	[[ -n "${FROM_CFENGINE:-}" ]] && exit ${EXIT_CF_FAILED:-1} || exit 1
} # die

function dbg() {
	(( debug )) && echo >&2 "DEBUG: $@"
	return $(( ! debug ))
} # dbg

function compare() {
	local ver1 ver2 part1 part2 num1 num2 rem1 rem2 done result

	(( 2 == $# )) || return

	ver1="$1"
	ver2="$2"
	rem1="$ver1"
	rem2="$ver2"

	(( compdebug )) && dbg "FUNC compare: Comparing '$ver1' and '$ver2'"

	if [[ "$ver1" == "$ver2" ]]; then
		(( compdebug )) && dbg "FUNC compare: Values are trivially identical"
		result="$ver1"
	else

		done=1
		separator='._-'
		while (( done )); do
			part1="$( grep "[$separator]" <<<"$rem1" >/dev/null && sed -r "s/^([^$separator]+)[$separator]+.*$/\1/" <<<"$rem1" || echo "$rem1" )"
			rem1="$( grep "[$separator]" <<<"$rem1" >/dev/null && sed -r "s/^[^$separator]+[$separator]+(.*)$/\1/" <<<"$rem1" )"
			part2="$( grep "[$separator]" <<<"$rem2" >/dev/null && sed -r "s/^([^$separator]+)[$separator]+.*$/\1/" <<<"$rem2" || echo "$rem2" )"
			rem2="$( grep "[$separator]" <<<"$rem2" >/dev/null && sed -r "s/^[^$separator]+[$separator]+(.*)$/\1/" <<<"$rem2" )"
			if [[ -z "$part1" ]]; then
				part1="$rem1"
				rem1=""
			fi
			if [[ -z "$part2" ]]; then
				part2="$rem2"
				rem2=""
			fi

			if [[ -n "$rem1" && -n "$rem2" ]]; then
				(( compdebug )) && dbg "FUNC compare: Comparing element '$part1'($rem1) and '$part2'($rem2) ..."
			else
				(( compdebug )) && dbg "FUNC compare: Comparing element '$part1' and '$part2' ..."
			fi

			if [[ "$part1" == "$part2" ]]; then
				if [[ -n "$rem1" && -n "$rem2" ]]; then
					(( compdebug )) && dbg "FUNC compare: Elements are equal, comparing following elements ..."
					# Continue...
				else
					if [[ -z "$rem1" && -z "$rem2" ]]; then
						(( compdebug )) && dbg "FUNC compare: Final elements are equal, values are identical"
						result="$ver1" # ... or $ver2, it matters not
						done=0
					else
						if [[ -n "$rem1" ]]; then
							(( compdebug )) && dbg "FUNC compare: Final matched elements are equal and first value is longer"
							(( compdebug )) && dbg "              First value is largest"
							result="$ver1"
							done=0
						elif [[ -n "$rem2" ]]; then
							(( compdebug )) && dbg "FUNC compare: Final matched elements are equal and second value is longer"
							(( compdebug )) && dbg "              Second value is largest"
							result="$ver2"
							done=0
						else
							(( compdebug )) && dbg "FUNC compare: LOGIC ERROR"
							result=""
							done=0
						fi
					fi
				fi
			else
				num1=0
				num2=0
				if [[ "$part1" == "$( echo "$part1" | awk '{ print strtonum( $0 ) }' )" ]]; then
					num1=1
				fi
				if [[ "$part2" == "$( echo "$part2" | awk '{ print strtonum( $0 ) }' )" ]]; then
					num2=1
				fi

				if (( 1 == num1 && 1 == num2 )); then
					(( compdebug )) && dbg "FUNC compare: Elements are numeric ..."
					if (( part1 < part2 )); then
						result="$ver2"
						done=0
					else
						result="$ver1"
						done=0
					fi
				elif (( num1 )); then
					(( compdebug )) && dbg "FUNC compare: First element is numeric ..."
					result="$ver1"
					done=0
				elif (( num2 )); then
					(( compdebug )) && dbg "FUNC compare: Second element is numeric ..."
					result="$ver2"
					done=0
				else
					(( compdebug )) && dbg "FUNC compare: Elements are both text ..."
					result="$( echo -e "${ver1}\n${ver2}" | sort -g | tail -n 1 )"
					done=0
				fi
			fi
		done
	fi

	(( compdebug )) && dbg "FUNC compare: Value '$result' is the greatest"
	echo "$result"
} # compare

function largest() {
	local parameter last

	(( compdebug )) && dbg "FUNC largest: Looking for largest value from list: $@"

	last="$1"
	(( compdebug )) && dbg "FUNC largest: Initial value is '$last'"
	#shift
	#parameter="$1"
	parameter="$2"
	shift 2
	(( compdebug )) && dbg "FUNC largest: Parameter '$parameter', remaining values: $@"
	while [[ -n "$parameter" ]]; do
		(( compdebug )) && dbg "FUNC largest: Comparing '$last' and '$parameter'"
		last="$( compare "$last" "$parameter" )"
		(( compdebug )) && dbg "FUNC largest: Largest value so far is '$last'"
		#shift
		#parameter="$1"
		parameter="$1"
		shift
		(( compdebug )) && dbg "FUNC largest: Parameter '$parameter', remaining values: $@"
	done
	(( compdebug )) && dbg "FUNC largest: Final largest value is '$last'"
	echo "$last"
}

if (( compdebug )); then
	dbg "INIT: Running 'compare' test suite ..."
	compare 1 1
	compare 1 2
	compare 2 1
	compare 2 2
	compare a a
	compare a b
	compare b a
	compare b b
	compare 1.1 1.1
	compare 1.2 1.1
	compare 1.1 1.2
	compare 1.2 1.2
	compare 2.1 2.1
	compare 2.1 1.1
	compare 1.1 2.1
	compare 2.2 2.2
	compare a.1 a.1
	compare a.2 a.1
	compare a.1 a.2
	compare a.2 a.2
	compare 2.a 1.a
	compare 1.a 2.a
	compare 2.a 2.a
	compare 1.2.3 1.2
	compare 1.2 1.2.3
	compare 1.2-3 1.2-3
	compare 1.2-4.3 1.2-3
	compare 1.2-4 1.2-3.4
	dbg "INIT: Running 'known failures' test suite ..."
	compare 1-2.3	1.2-3
	compare 1.2 1--2
	compare 1.2 1..2
	dbg "INIT: Running 'largest' test suite ..."
	largest 1 1
	largest 1 2
	largest 2 1
	largest 1 2 3 4 5 6 7 8 9 10
	largest 10 9 8 7 6 5 4 3 2 1
	largest 1 10 2 3 4 5 6 7 8 9
	largest 1 2 10 3 4 5 6 7 8 9
fi

LOGDIR="/var/log/"

RPM="$( readlink -e "$( type -pf rpm )" 2>/dev/null || readlink -f "$( type -pf rpm )" 2>/dev/null )"
RPM_PATTERN="%{n}-%{v}-%{r}.%{arch}\n"

(( trace )) && set -o xtrace

declare help=0
while [[ -n "${1:-}" ]]; do
	case "${1}" in
		--arch*)
			if [[ "$1" == "--arch" ]]; then
				shift
				ARCH="$1"
			elif [[ "$1" =~ --arch=.*$ ]]; then
				ARCH="$( cut -d'=' -f 2- <<<"$1" )"
			fi
			;;
		-c*|-C*|--location*)
			# NB: This can also be specified by setting 'PKGDIR' in
			#     the environment.
			if [[ "$1" =~ ^-[cC]$ ]] || [[ "$1" == "--location" ]]; then
				shift
				RDIR="$1"
			elif [[ "$1" =~ ^-[cC]=.*$ ]] || [[ "$1" =~ ^--location=.*$ ]]; then
				RDIR="$( cut -d'=' -f 2- <<<"$1" )"
			fi
			if [[ -z "${RDIR}" ]]; then
				help=1
			fi
			;;
		-d|--debug)
			debug=1
			;;
		-h|--help)
			help=1
			;;
		--host*)
			if [[ "$1" == "--host" ]]; then
				shift
				HOST="$1"
			elif [[ "$1" =~ ^--host=.*$ ]]; then
				HOST="$( cut -d'=' -f 2- <<<"$1" )"
			fi
			if [[ -z "${HOST}" ]]; then
				help=1
			fi
			;;
		-p*|--pkg*)
			PKG=""
			if [[ "$1" == "-p" ]] || [[ "$1" == "--pkg" ]]; then
				shift
				PKG="$1"
			elif [[ "$1" =~ ^-p=.*$ ]] || [[ "$1" =~ --pkg=.*$ ]]; then
				PKG="$( cut -d'=' -f 2- <<<"$1" )"
			fi
			if [[ -n "$PKG" ]]; then
				o1=0
				o2=0
				oo=0
			else
				help=1
			fi
			;;
		-q*|--quickstart*)
			QSF=""
			if [[ "$1" == "-q" ]] || [[ "$1" == "--quickstart" ]]; then
				shift
				QSF="$1"
			elif [[ "$1" =~ ^-q=.*$ ]] || [[ "$1" =~ --quickstart=.*$ ]]; then
				QSF="$( cut -d'=' -f 2- <<<"$1" )"
			fi
			if [[ -z "${QSF}" ]]; then
				help=1
			fi
			;;
		--dry-run)
			:
			;;
		*)
			help=1
			;;
	esac
	shift
done

if (( help )); then
	USAGE="Usage: $( basename "$0" )	[--arch <architecture>] ...
				[-p|--pkg <package name>] ...
				[-q|--quickstart <quickstart file>] ...
                        	[-c|--location <path to repo>] ...
				   [--host <hostname>] [-d|--debug] [-h|--help]

Environment variables:  	PKGDIR -    Path within rsync repo 'install'
                        	            directory to search for packages.
                        	            Default: 'vendor/*'
                        	ARCH -      Package architecture.
                        	            Default: '$( uname -i )'
                        	DEBUG -     Enable debug output
                        	            Default: '0'
                        	COMPDEBUG - Enable computational debug output
                        	            Default: '0'"

	echo -e "$USAGE"
	[[ -n "${FROM_CFENGINE:-}" ]] && exit ${EXIT_CF_FAILED:-1} || exit 0
fi

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
if ! "$RTOOL" --version | grep -Eq "version [0-2]" >/dev/null 2>&1; then
	# rsync-3.x feature
	RARGS="--list-only"
fi
RPATH="${REPO}/${RDIR}"
RDEST="rsync://${RPATH}/*/*.rpm" # => rsync://rpmrepo/vendor/*/*/*.rpm

if ! [[ -x "$RPM" ]]; then
	die "Prerequisites not met (cannot locate 'rpm' executable): Aborting"
elif ! [[ -x "$RTOOL" || -s "$QSF" ]]; then
	die "Prerequisites not met (cannot locate 'rsync' executable): Aborting"
fi

LIST="$( "$RPM" -qa --qf "$RPM_PATTERN" | sed '/PGDG/s/^postgresql-/PGDG-postgresql-/' | sort | uniq )"
[[ -n "$PKG" ]] && { echo >&2 -n " $PKG" ; LIST="$PKG" ; unset PKG ; }

echo >&2

if [[ -z "$QSF" ]]; then
	REPOLIST="$( "$RTOOL" $RARGS "$RDEST" 2>/dev/null | awk '{ print $5 }' )" || die "rsync from '$RDEST' failed: $?"
elif [[ -n "$QSF" && ! -s "$QSF" ]]; then
	REPOLIST="$( "$RTOOL" $RARGS "$RDEST" 2>/dev/null | awk '{ print $5 }' | tee "$QSF" )" || { rm "$QSF" ; die "rsync from '$RDEST' failed: $?" ; }
else # [[ -n "$QSF" && -s "$QSF" ]]; then
	REPOLIST="$( cat "$QSF" )"
	[[ -n "$REPOLIST" ]] || die "Load from '$QSF' cache failed"
fi

PREFERARCH="${ARCH:-$( uname -i )}"
unset ARCH

for OPKG in $LIST; do
	# Try to cope with horrendous PostgreSQL versioning issues on Red Hat :(
	MULTIVERSIONEXCLUDE=""
	# And allow multiple versions of Java to co-exist...
	ARCH=""
	PKG=""

	if grep -E '\.(noarch|i[3-6]86|x86_64)(\.rpm)?$' <<<"$OPKG" >/dev/null 2>&1; then
		ARCH="$( sed -r 's/^.*\.(noarch|i[3-6]86|x86_64)(\.rpm)?$/\1/' <<<"$OPKG" )"
		PKG="$( sed -r 's/\.(noarch|i[3-6]86|x86_64)(\.rpm)?$//' <<<"$OPKG" )"
		dbg "Package '$PKG', architecture '$ARCH' from entry '$OPKG'"
	else
		PKG="$OPKG"
		if [[ -n "$ARCH" ]]; then
			dbg "Package '$PKG', architecture '$ARCH'"
		else
			dbg "Package '$PKG'"
		fi
	fi
	[[ -n "$ARCH" ]] || ARCH="$PREFERARCH"

	# If not weirdly-named, use a standard pattern to find name and version...
	# The same operation needs to be applied to $RESULT below
	if [[ "$PKG" =~ gpg-pubkey ]]; then
		NAME="gpg-pubkey"
		VERSION="$( echo "$PKG" | sed -r 's/^gpg-pubkey-(.*)$/\1/' )"
	elif [[ "$PKG" =~ compat-libstdc ]]; then
		NAME="$( cut -d'-' -f -3 <<<"$PKG" )"
		VERSION="$( cut -d'-' -f 4- <<<"$PKG" | sed -r 's/\.(noarch|i[3-6]86|x86_64)$//' )"
	elif [[ "${PKG:0:5}" == "PGDG-" ]]; then
		dbg "Adjusting for multi-version package ..."
		MULTIVERSIONEXCLUDE=""
		NAME="$( echo "${PKG:5}" | sed 's/-[0-9].*$//' )"
		VERSION="$( echo "${PKG:5}" | perl -pe 's/^.*?-([0-9].*)$/\1/' | sed -r 's/\.(noarch|i[3-6]86|x86_64)$//' )"
	elif [[ "$PKG" =~ postgresql ]]; then
		dbg "Excluding 'PGDG' packages ..."
		MULTIVERSIONEXCLUDE="PGDG"
		NAME="$( echo "$PKG" | sed 's/-[0-9].*$//' )"
		VERSION="$( echo "$PKG" | perl -pe 's/^.*?-([0-9].*)$/\1/' | sed -r 's/\.(noarch|i[3-6]86|x86_64)$//' )"
	elif [[ "$PKG" =~ ^java ]]; then
		NAME="$( echo "$PKG" | sed -r 's/^(java-[0-9.]+-[a-zA-Z-]+)-[0-9].*$/\1/' )"
		VERSION="$( echo "$PKG" | sed -r 's/^java-[0-9.]+-[a-zA-Z-]+-([0-9].*)$/\1/ ; s/\.(noarch|i[3-6]86|x86_64)$//' )"
	else
		NAME="$( echo "$PKG" | sed 's/-[0-9].*$//' )"
		VERSION="$( echo "$PKG" | perl -pe 's/^.*?-([0-9].*)$/\1/' | sed -r 's/\.(noarch|i[3-6]86|x86_64)$//' | sed "s|^$PKG||" )"
	fi
	dbg "Read package name '$NAME' with version '$VERSION'"

	RESULT="$( echo "$REPOLIST" | grep "${ARCH}\.rpm$" | sed -r 's/\.(noarch|i[3-6]86|x86_64)\.rpm$//' | grep "^$NAME-[0-9]" | grep -Ev "${MULTIVERSIONEXCLUDE:-__DO_NOT_MATCH__}" | sort | uniq )"
	# TODO: If the supplied package doesn't match the system architecture,
	#       we currently need to try to see whether its a 'noarch' package.
	#       There may be a cleaner way to achieve this...
	[[ -n "${RESULT}" ]] || for CHECKARCH in $( echo noarch i{3,4,5,6}86 x86_64 ); do
		[[ "${CHECKARCH}" != "${ARCH}" ]] && RESULT="$( echo "$REPOLIST" | grep "${CHECKARCH}\.rpm$" | sed -r 's/\.(noarch|i[3-6]86|x86_64)\.rpm$//' | grep "^$NAME-[0-9]" | grep -Ev "${MULTIVERSIONEXCLUDE:-__DO_NOT_MATCH__}" | sort | uniq )"
		[[ -n "${RESULT}" ]] && break
	done
	unset CHECKARCH
	
	if [[ -n "$RESULT" ]]; then
		# Package name mangling should match the list above...
		if [[ "$RESULT" =~ gpg-pubkey ]]; then
			RNAME="gpg-pubkey"
			RVERSION="$( echo "$RESULT" | sed -r 's/^gpg-pubkey-(.*)$/\1/' )"
		elif [[ "$RESULT" =~ compat-libstdc ]]; then
			RNAME="$( cut -d'-' -f -3 <<<"$RESULT" )"
			RVERSION="$( cut -d'-' -f 4- <<<"$RESULT" )"
		else
			RNAME="$( echo "$RESULT" | sed 's/-[0-9].*$//' | sort | uniq )"
			RVERSION="$( echo "$RESULT" | perl -pe 's/^.*?-([0-9].*)$/\1/' )"
			dbg "Detected version(s) '$( xargs echo <<<"$RVERSION" )'"
			if (( 1 != $( wc -l <<<"$RVERSION" ) )); then
				echo >&2 -e "WARN: Multiple canidate versions detected for package '$NAME':\n$RVERSION"
				RVERSION="$( largest $( echo $RVERSION ) )"
				echo >&2 "NOTICE: Choosing version '$RVERSION'"
			fi
		fi
		if [[ "$NAME" != "$RNAME" ]]; then
			echo >&2 "WARN: Ambiguous package name '$NAME' (matched '$RNAME')"
		else
			if [[ "$VERSION" == "$RVERSION" ]]; then
				echo >&2 "NOTICE: Package '$NAME' (version '$VERSION') does not need upgrading"
			else
				# Assume that if versions don't match, repo
				# version is most recent.
				# This could be determined numerically, but
				#  installed-version > repo-version
				# isn't a use-case we should be dealing with...
				# VERSION is null if invoked with '-p'
				if [[ "$VERSION" == "$PKG" || -z "$VERSION" ]]; then
					echo >&2 "Package '$NAME' has upgrade version '$RVERSION'"
				else
					echo >&2 "Package '$NAME' has installed version '$VERSION' upgrade version '$RVERSION'"
				fi
				RESULT="$( echo "$REPOLIST" | grep "^$NAME-$RVERSION" | sort | uniq )"
				if (( 1 != $( wc -l <<<"$RESULT" ) )); then
					dbg "Multiple candidate versions - checking for arch-specific packages"
					if (( 1 == $( grep "$ARCH" <<<"$RESULT" | wc -l ) )); then
						dbg "Options reduced to single package"
						RESULT="$( grep "$ARCH" <<<"$RESULT" )"
					else
						echo >&2 -e "WARN: Multiple upgrade versions for package '$NAME':\n$RESULT\nChoosing last"
						RESULT="$( tail -n 1 <<<"$RESULT" )"
					fi
				fi
				echo "UPGRADE: $RESULT"
			fi
		fi
	else
		echo "WARNING: No match in repository for package '$NAME' ('$ARCH')"
		# The 'exit' on the following line was commented-out - likely
		# so as not to fail if package-lists contain invalid entries
		# (which should themselves be fixed...) - but since we haven't
		# recorded these, this can go back in, at least in order to
		# rediscover these issues...
		#exit ${EXIT_CF_FAILED:-1}
		[[ -n "${FROM_CFENGINE:-}" ]] && exit ${EXIT_CF_FAILED:-1} || exit 1
	fi
done

[[ -n "${FROM_CFENGINE:-}" ]] && exit ${EXIT_CF_REPAIRED:-0} || exit 0

