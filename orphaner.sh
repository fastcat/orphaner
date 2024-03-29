#!/bin/sh

# Orphaner is a neat frontend for deborphan displaying a list of orphaned
# packages with dialog. Packages may be selected for removal with apt-get which
# is then called to do the work. After removal a new list of orphaned packages
# is gathered from deborphan. The program ends when either `Cancel' is pressed
# or no package is marked for removal. Most options are passed on to deborphan.

# Copyright (c) 2000 Goswin Brederlow <goswin-v-b@web.de>
# Copyright (c) 2000, 2003, 2004, 2005, 2006 Peter Palfrader <peter@palfrader.org>
# Copyright (c) 2001, 2003 Cris van Pelt <tribbel@tribe.eu.org>
# Copyright (c) 2003, 2004, 2007, 2008 Jörg Sommer <joerg@alea.gnuu.de>
# Copyright (c) 2008, 2009 Carsten Hey <carsten@debian.org>
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -e


OPTIONS=$@
VALIDOPTIONS='^-([aHns]|-libdevel|-guess-(.+)|-find-(.+)|-ignore-(suggests|recommends)|-nice-mode|-all-packages|-priority(.+)|p(.+)|-show-section|-force-hold)[[:space:]]$'
VALIDKEEPOPTIONS='^-([aHns]|-libdevel|-guess-(.+)|-find-(.+)|-ignore-(suggests|recommends)|-nice-mode|-all-packages|-priority(.+)|p(.+)|-show-section|-force-hold)[[:space:]]$'
SKIPAPT=0
CIRCULAR=0

# LC_COLLATE=pl_PL or similar breaks orphaner under some circumstances, see
# Debian bug #495818.
export LC_COLLATE=C

if which gettext > /dev/null; then
	. gettext.sh
else
	gettext() {
		echo "$@"
	}
fi

TEXTDOMAIN=deborphan
export TEXTDOMAIN
# xgettext:sh-format
USAGE=$(gettext 'Usage: %s [--help|--purge|--skip-apt] [deborphan options]')'\n'
# xgettext:no-sh-format
SEE_ORPHANER=$(gettext 'See orphaner(8) and deborphan(1) for a list of valid options.')
# xgettext:sh-format
INVALID_BASENAME=$(gettext 'Invalid basename: %s.')'\n'
# xgettext:sh-format
INVALID_OPTION=$(gettext '%s: Invalid option: %s.')'\n'
# xgettext:sh-format
MISSING_DIALOG=$(gettext '%s: You need "dialog" in $PATH to run this frontend.')'\n'
# xgettext:no-sh-format
SCREEN_TOO_SMALL=$(gettext 'Screen too small or set $LINES and $COLUMNS.')

# xgettext:no-sh-format
EDIT_KEEP_INSTRUCTION=$(gettext 'Select packages that should never be recommended for removal in deborphan:')
# xgettext:no-sh-format
ORPHANER_INSTRUCTION=$(gettext 'Select packages for removal or cancel to quit:')

# xgettext:no-sh-format
NO_ORPHANS_FOUND=$(gettext 'No orphaned packages found.')
# xgettext:no-sh-format
DEBORPHAN_REMOVED=$(gettext '"deborphan" got removed.  Exiting.')
# xgettext:no-sh-format
APT_GET_REMOVED=$(gettext '"apt" got removed.  Exiting.')
# xgettext:no-sh-format
APT_GET_LOCKFAIL=$(gettext '"apt" is not installed, broken dependencies found or could not open lock file, are you root?  Printing "apt-get" commandline and exiting:')
SKIPAPT_SET=$(gettext 'Explicitly specified status file or requested calling "apt-get" to be skipped.  Printing "apt-get" commandline and exiting:')
# xgettext:no-sh-format
REMOVING=$(gettext 'Removing %s')'\n'

# xgettext:no-sh-format
DEBORPHAN_ERROR=$(gettext '"deborphan" returned with error.')
# xgettext:sh-format
APT_GET_ERROR=$(gettext '"apt-get" returned with exitcode %s.')'\n'
# xgettext:sh-format
DIALOG_ERROR=$(gettext '"dialog" returned with exitcode %s.')'\n'
# xgettext:no-sh-format
NUMBER_OF_PACKAGES_ERROR=$(gettext '"apt-get" tries to remove more packages than requested by "orphaner".  Exiting.')'\n'

# xgettext:no-sh-format
SIMULATE_BUTTON=$(gettext 'Simulate')

# xgettext:no-sh-format
PRESS_ENTER_TO_CONTINUE=$(gettext 'Press enter to continue.')

# xgettext:no-sh-format
CIRCULAR_NOT_SUPPORTED=$(gettext '"find-circular" is currently not supported by "orphaner".  Exiting.')

if ! which dialog >/dev/null ; then
	printf "$MISSING_DIALOG" $0 >&2
	exit 1
fi

# Plea for help?
case " $OPTIONS " in
	*" --help "*|*" -h "*)
		printf "$USAGE" $0
		echo
		echo $SEE_ORPHANER
		exit 0
		;;
esac

# Adapt to terminal size
if [ -n "${LINES:-}" -a -n "${COLUMNS:-}" ]; then
	# Can't use LINES, because it colides with magic variable
	# COLUMNS ditto
	lines=$(($LINES - 7))
	columns=$(($COLUMNS - 10))

	# unset these magic variables to avoid unwished effects
	unset LINES COLUMNS
else
	size=$(stty size)
	lines=$((${size% *} - 7))
	columns=$((${size#* } - 10))

	sigwinch_handle()
	{
		size=$(stty size)
		lines=$((${size% *} - 7))
		columns=$((${size#* } - 10))

		if [ $lines -ge 12 -a $columns -ge 50 ]; then
			LISTSIZE="$lines $columns $(($lines - 7))"
			BOXSIZE="$lines $columns"
		fi
	}

	trap sigwinch_handle WINCH
fi

if [ $lines -lt 12 -o $columns -lt 50 ]; then
	echo $SCREEN_TOO_SMALL >&2
	exit 1
fi

LISTSIZE="$lines $columns $(($lines - 7))"
BOXSIZE="$lines $columns"

editkeepers() { #{{{
	for each in $OPTIONS; do
		if [ "$SKIPONE" = "1" ]; then
			SKIPONE=0;
		elif [ " $each" = " --keep-file" -o " $each" = " -k" ]; then
			SKIPONE=1;
		elif [ " $each" = " --status-file" -o " $each" = " -f" ]; then
			SKIPONE=1;
		elif ! echo "$each " | egrep $VALIDKEEPOPTIONS >/dev/null; then
			case "$each" in
				--status-file* | -f* | --keep-file* | -k*)
					;;
				*)
					printf "$INVALID_OPTION" $0 $each >&2
					exit 1
					;;
			esac;
		fi
	done

	ORPHANED=`keeping_list $OPTIONS | sort`;
	# insert clever error handling

	if [ -n "$ORPHANED" ]; then
		PACKAGES=`mktemp`;
		ERROR=0
		dialog \
			--backtitle "Orphaner" \
			--separate-output \
			--title "Orphaner" \
			--checklist "$EDIT_KEEP_INSTRUCTION" \
			$LISTSIZE \
			$ORPHANED \
			2> $PACKAGES || ERROR=$?

		case $ERROR in
			0) # OK-Button
				if LC_MESSAGES=C deborphan --help | grep -q 'Do not read debfoster'; then
					NODF="--df-keep"
				fi

				deborphan ${NODF} --zero-keep $OPTIONS
				if [ -s $PACKAGES ]; then
					deborphan --add-keep - $OPTIONS < $PACKAGES
				fi
				;;
			*) # other button or state
				# do nothing
		esac
		rm $PACKAGES
	fi
} #}}}

keeping_list() { #{{{
	{
		{ deborphan --no-show-arch --all-packages-pristine $@ || echo "ERROR"; } \
			| while read SECTION PACKAGE; do
			echo $PACKAGE $SECTION off
		done
		{ deborphan -L $@ 2>/dev/null || echo "ERROR"; } \
			| while read PACKAGE; do
			echo $PACKAGE "." on
		done
	} | sort -u
} #}}}

deborphan_list() { #{{{
	{ deborphan -s $@ || echo "ERROR"; } \
		| while read SECTION PACKAGE; do
		echo $PACKAGE $SECTION off
	done
} #}}}

doorphans() { #{{{
	# Check options {{{
	skipone=0
	for each in $OPTIONS; do
		if [ "$skipone" = "1" ]; then
			skipone=0;
		elif [ " $each" = " --keep-file" -o " $each" = " -k" ]; then
			skipone=1;
		elif [ " $each" = " --status-file" -o " $each" = " -f" ]; then
			skipone=1;
		elif ! echo "$each " | egrep -q $VALIDOPTIONS; then
			case "$each" in
				--status-file* | -f* | --keep-file* | -k*)
					;;
				*)
					printf "$INVALID_OPTION" $0 $each >&2
					exit 1
					;;
			esac
		fi
	done #}}}

	TMPFILE=`mktemp`
	trap "rm -f $TMPFILE" EXIT INT

	EXCLUDE=
	ORPHANED=
	# Don't touch the next two lines! This is correct! NL should be the newline
	# character
	NL='
'
	while true; do
		OLD_ORPHANED="$ORPHANED"
		ORPHANED=$(deborphan_list $OPTIONS ${EXCLUDE:+--exclude=$EXCLUDE} | sort)
		if [ "$ORPHANED" = "ERROR off" ] ; then
			echo $DEBORPHAN_ERROR >&2
			exit 1
		fi

		if [ -z "$ORPHANED$EXCLUDE" ]; then #{{{# nothing to do
			dialog \
				--backtitle "Orphaner" \
				--title "Orphaner" \
				--msgbox "$NO_ORPHANS_FOUND" \
				$BOXSIZE
			break #}}}
		elif [ -z "$OLD_ORPHANED" ]; then #{{{# it's the first loop cycle
			SPLIT_NEW=
			SPLIT_OLD="$ORPHANED" #}}}
		elif [ -z "$ORPHANED" ]; then #{{{# maybe we have excluded all packages and no new packages were orphaned
			ORPHANED="$OLD_ORPHANED"
			SPLIT_NEW=
			SPLIT_OLD=
			while read LINE; do
				SPLIT_OLD="$SPLIT_OLD$NL${LINE%off}on"
			done <<__OORPH_EOT
$OLD_ORPHANED
__OORPH_EOT

			SPLIT_OLD="${SPLIT_OLD#$NL}" # trim leading newline character }}}
		else #{{{# normal loop cycle
			# Idea: you have two sorted lists: the list of the
			# orphaned packages in the last cycle and the list of
			# orphaned packages in this cycle. Now you compare element
			# by element if the lists differ.
			exec 3<<__ORPH_EOT
$ORPHANED
__ORPH_EOT
			exec 4<<__OORPH_EOT
$OLD_ORPHANED
__OORPH_EOT
			read LINE <&3
			read OLD_LINE <&4
			SPLIT_NEW=
			SPLIT_OLD=
			if [ -n "$EXCLUDE" ]; then
				# If we exclude some packages, the list of orphaned
				# packages is incomplete. So we build up the list from
				# scratch
				ORPHANED=
			fi
			while true; do #{{{
				if [ "$LINE" ">" "$OLD_LINE" ]; then
					# The package from the old orphaned list was removed
					if [ -n "$EXCLUDE" ]; then
						# ...but not really, it is only excluded
						ORPHANED="$ORPHANED$NL$OLD_LINE"
						SPLIT_OLD="$SPLIT_OLD$NL${OLD_LINE%off}on"
					fi

					read OLD_LINE <&4 || break
				else
					if [ -n "$EXCLUDE" ]; then
						ORPHANED="$ORPHANED$NL$LINE"
					fi

					if [ "$LINE" = "$OLD_LINE" ]; then
						# ophaned packages are equal no changes
						SPLIT_OLD="$SPLIT_OLD$NL$LINE"
						LINE=
						read OLD_LINE <&4 || break
					else # $LINE < $OLD_LINE
						# there is a new package in the orphaned list
						SPLIT_NEW="$SPLIT_NEW$NL$LINE"
					fi

					if ! read LINE <&3; then
						# the new orphaned list reached the end, all
						# packages from the old orphaned list are
						# removed
						if [ -n "$EXCLUDE" ]; then
							# ...but not really, they are only excluded
							ORPHANED="$ORPHANED$NL$OLD_LINE"
							SPLIT_OLD="$SPLIT_OLD$NL${OLD_LINE%off}on"
							while read OLD_LINE; do
								ORPHANED="$ORPHANED$NL$OLD_LINE"
								SPLIT_OLD="$SPLIT_OLD$NL${OLD_LINE%off}on"
							done <&4
						fi
						break
					fi
				fi
			done #}}}
			exec 4<&-

			# The list of old orphaned packages reached the end. So
			# all remaining new orphaned packages are new
			if [ -n "$LINE" ]; then
				if [ -n "$EXCLUDE" ]; then
					ORPHANED="$ORPHANED$NL$LINE"
				fi
				SPLIT_NEW="$SPLIT_NEW$NL$LINE"
			fi
			while read LINE; do
				if [ -n "$EXCLUDE" ]; then
					ORPHANED="$ORPHANED$NL$LINE"
				fi
				SPLIT_NEW="$SPLIT_NEW$NL$LINE"
			done <&3
			exec 3<&-

			# trim leading newline characters
			ORPHANED="${ORPHANED#$NL}"
			SPLIT_OLD="${SPLIT_OLD#$NL}"
			SPLIT_NEW="${SPLIT_NEW#$NL}"
		fi #}}}

		# Display dialog box and handle buttons {{{
		while true; do
			ERROR=0
			dialog --backtitle "Orphaner" \
				--defaultno \
				${DEFAULT_PKG:+--default-item $DEFAULT_PKG} \
				--separate-output \
				--title "Orphaner" \
				--help-button --help-status --extra-button --extra-label "$SIMULATE_BUTTON" \
				--checklist "$ORPHANER_INSTRUCTION" \
				$LISTSIZE ${SPLIT_NEW:+$SPLIT_NEW ---- _new_packages_above_ off} \
				$SPLIT_OLD 2> $TMPFILE || ERROR=$?

			unset DEFAULT_PKG EXCLUDE

			case $ERROR in
				0) # OK-Button {{{
					if [ ! -s $TMPFILE ]; then
						# nothing's selected
						break 2
					fi
					clear
					# tr , ' ' is used for compatibility with the svn branch deborphan-2.0
					PACKAGES_TO_REMOVE="$(printf '%s ' $(grep -v '^----$' $TMPFILE | tr , ' '))"
					PACKAGES_TO_REMOVE="${PACKAGES_TO_REMOVE% }"
#					printf "$REMOVING" "$PACKAGES_TO_REMOVE"
					APT_GET_CMDLN="apt-get $PURGE --show-upgraded --assume-yes remove $PACKAGES_TO_REMOVE"
					if apt-get check -q -q 2> /dev/null && [ $SKIPAPT -eq 0 ]; then
						$APT_GET_CMDLN || ERROR=$?
					else
						if [ $SKIPAPT -eq 0 ]; then
							printf '%s\n' "$APT_GET_LOCKFAIL" >&2
						else
							printf '%s\n' "$SKIPAPT_SET" >&2
						fi
						printf '%s\n' "$APT_GET_CMDLN"
						exit 1
					fi
					unset APT_GET_CMDLN PACKAGES_TO_REMOVE
					if [ $ERROR -ne 0 ]; then
						printf "$APT_GET_ERROR" $ERROR >&2
						exit 1
					fi
					if ! which deborphan >/dev/null 2>&1; then
						echo $DEBORPHAN_REMOVED
						exit 0;
					fi
					if ! which apt-get >/dev/null 2>&1; then
						echo $APT_GET_REMOVED
						exit 0;
					fi
					echo
					echo "$PRESS_ENTER_TO_CONTINUE"
					read UNUSED_VARIABLE_NAME
					break
					;; #}}}
				1) # Cancel-Button #{{{
					break 2
					;; #}}}
				2) # Help-Button #{{{
					SEL_LIST=
					while read pkg; do
						case "$pkg" in
							"HELP "*)
								# DEFAULT_PKG is default item in the
								# next dialog
								DEFAULT_PKG=${pkg#HELP }
								;;
							*)
								SEL_LIST="$SEL_LIST $pkg"
								;;
						esac
					done < $TMPFILE

					if test -n "$SPLIT_NEW"; then
						while read pkg rest; do
							new_SPLIT_NEW="$new_SPLIT_NEW$NL$pkg $rest"
							# check if the selection for every new
							# orphaned package changed
							case "$SEL_LIST " in
								*" $pkg "*) # now it is selected...
									case "$rest" in
										*' off') # ...but wasn't before
											new_SPLIT_NEW="${new_SPLIT_NEW%off}on"
									esac
									;;
								*) # now it is deselected...
									case "$rest" in
										*' on') # ...but it was selected before
											new_SPLIT_NEW="${new_SPLIT_NEW%on}off"
									esac
									;;
							esac
						done <<__EOT
$SPLIT_NEW
__EOT
						SPLIT_NEW="${new_SPLIT_NEW#$NL}"
						unset new_SPLIT_NEW
					fi

					while read pkg rest; do
						new_SPLIT_OLD="$new_SPLIT_OLD$NL$pkg $rest"
						# check if the selection for every old ophaned
						# package changed
						case "$SEL_LIST " in
							*" $pkg "*) # now it is selected...
								case "$rest" in
									*' off') # ...but wasn't before
										new_SPLIT_OLD="${new_SPLIT_OLD%off}on"
								esac
								;;
							*) # now it is deselected...
								case "$rest" in
									*' on') # ...but it was selected before
										new_SPLIT_OLD="${new_SPLIT_OLD%on}off"
								esac
								;;
						esac
					done <<__EOT
$SPLIT_OLD
__EOT
					SPLIT_OLD="${new_SPLIT_OLD#$NL}"
					unset new_SPLIT_OLD

					dpkg -s $DEFAULT_PKG > $TMPFILE
					dialog --backtitle "Orphaner" \
						--title "Orphaner" \
						--textbox $TMPFILE $BOXSIZE
					;; #}}}
				3) # Simulate-Button #{{{
					EXCLUDE=$(grep -v '^----$' $TMPFILE | while read pkg; do printf $pkg,; done)
					EXCLUDE=${EXCLUDE%,}
					break
					;; #}}}
				*) #{{{
					printf "$DIALOG_ERROR" $ERROR >&2
					cat $TMPFILE
					exit 1 #}}}
			esac
		done #}}}
	done #}}}
} #}}}

# parse options # {{{
case " $OPTIONS " in
	*" --purge "*)
		OPTIONS="${OPTIONS%%--purge*}${OPTIONS#*--purge}"
		PURGE=--purge
		;;
esac

case " $OPTIONS " in
	*" -f "*)
		SKIPAPT=1
		;;
	*" --status-file"*)
		SKIPAPT=1
		;;
esac

case " $OPTIONS " in
	*" -c "*)
		CIRCULAR=1
		;;
	*" --find-circular"*)
		CIRCULAR=1
		;;
esac

case " $OPTIONS " in
	*" --skip-apt "*)
		OPTIONS="${OPTIONS%%--skip-apt*}${OPTIONS#*--skip-apt}"
		SKIPAPT=1
		;;
esac
# }}}

if [ $CIRCULAR -eq 1 ]; then
	printf '%s\n' "$CIRCULAR_NOT_SUPPORTED" >&2
	exit 1
fi

case $0 in
	*orphaner|*orphaner.sh) doorphans;;
	*editkeep) editkeepers;;
	*)
		printf "$INVALID_BASENAME" $0 >&2
		exit 1
		;;
esac

clear
