# The learner's interactive shell (epr-consulting/lab-images#12), sourced by
# /etc/bash.bashrc after the history hook in every interactive bash of the
# control image. kube.bash adds what needs kubectl.
#
# The shell starts in /tmp with HOME=/tmp/student, which an empty /tmp does not
# hold yet. Create it and start there.
if [[ $PWD == /tmp ]]; then
	mkdir -p -- "$HOME" && cd -- "$HOME"
fi

# Colours for the prompt, ls, grep and less. Readline's own settings are in
# /etc/mylabskills/inputrc.
eval "$(dircolors -b)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'
export LESS=-R
# The coloured prompt has room for what kube.bash puts in __mylabskills_kube.
# The pod's hostname is a session id, so the prompt names the machine "lab".
PS1='\[\e[1;32m\]\u@lab\[\e[0m\]:\[\e[1;34m\]\w\[\e[33m\]${__mylabskills_kube}\[\e[0m\]\$ '
