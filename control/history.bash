# The learner's shell history (epr-consulting/backend#370), sourced by
# /etc/bash.bashrc in every interactive bash of the control image.
#
# Each finished command is appended to /tmp/.mylabskills_history after a
# "#<epoch seconds>" line. Only the commands are written, never their output.
# The file lives in the pod's writable /tmp, so it ends with the session, and
# stays under 64 KiB. A command typed after a space is not recorded. The
# backend reads the end of this file only when the learner shares their recent
# commands with an AI hint.
HISTFILE=/tmp/.mylabskills_history
HISTSIZE=1000
HISTFILESIZE=1000
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignorespace
# A second terminal's commands are kept when one exits.
shopt -s histappend
# No history expansion: a "!" means what it means under /bin/sh.
set +H

# Appends the command that just finished. Past 64 KiB the file is cut to its
# last 32 KiB; the reader drops a command the cut split.
__mylabskills_history() {
	history -a
	local size
	size=$(stat -c %s -- "$HISTFILE" 2>/dev/null) || return 0
	if ((size > 65536)); then
		tail -c 32768 -- "$HISTFILE" >"$HISTFILE.cut" && mv -f -- "$HISTFILE.cut" "$HISTFILE"
	fi
}
PROMPT_COMMAND=__mylabskills_history
