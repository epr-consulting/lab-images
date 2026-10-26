# kubectl in the learner's shell (epr-consulting/lab-images#12), sourced by
# /etc/bash.bashrc after shell.bash. Tiers without kubectl skip all of it.
command -v kubectl >/dev/null || return 0

# As in the CKA and CKAD environment. kubectl itself stays plain; kubecolor is
# opt-in with `alias kubectl=kubecolor`, and k follows the alias.
alias k=kubectl
. /usr/share/bash-completion/completions/kubectl
complete -o default -F __start_kubectl k
complete -o default -F __start_kubectl kubecolor

# $KUBECONFIG is the Secret mount: read-only, and empty or missing until the
# Secret appears. Once it has content, copy it to ~/.kube/config and use the
# copy, so `kubectl config set-context` works. A copy that already exists (a
# second terminal, or an earlier prompt) stays as the learner left it, also when
# two terminals copy at once: the rename never replaces a file.
__mylabskills_kubeconfig() {
	local copy=$HOME/.kube/config tmp
	[[ ${KUBECONFIG-} == "$copy" ]] && return 0
	if [[ ! -s $copy ]]; then
		[[ -s ${KUBECONFIG-} ]] || return 0
		mkdir -p -m 700 -- "$HOME/.kube" || return 0
		tmp=$copy.$$
		install -m 600 -T -- "$KUBECONFIG" "$tmp" && mv -n -T -- "$tmp" "$copy"
		rm -f -- "$tmp"
	fi
	[[ -s $copy ]] && export KUBECONFIG=$copy
}

# The prompt shows the namespace, and the context as well once the kubeconfig
# has more than one: a session's own context has a long generated name. One
# kubectl call reads them, and only when the kubeconfig's mtime has changed
# since the last prompt.
__mylabskills_kube_prompt() {
	__mylabskills_kubeconfig
	local file=${KUBECONFIG:-$HOME/.kube/config} stamp info current name ns namespace=
	local -i contexts=0
	if [[ ! -s $file ]]; then
		__mylabskills_kube= __mylabskills_kube_seen=
		return 0
	fi
	stamp=$file:$(stat -c %.9Y -- "$file" 2>/dev/null)
	[[ $stamp == "${__mylabskills_kube_seen-}" ]] && return 0
	__mylabskills_kube_seen=$stamp
	__mylabskills_kube=
	info=$(kubectl config view -o jsonpath='{.current-context}{"\n"}{range .contexts[*]}{.name}{"\t"}{.context.namespace}{"\n"}{end}' 2>/dev/null) || return 0
	{
		read -r current
		while IFS=$'\t' read -r name ns; do
			contexts+=1
			[[ $name == "$current" ]] && namespace=$ns
		done
	} <<<"$info"
	[[ -n $current ]] || return 0
	if ((contexts > 1)); then
		__mylabskills_kube=" ($current:${namespace:-default})"
	else
		__mylabskills_kube=" (${namespace:-default})"
	fi
}

__mylabskills_kubeconfig
# After the history hook, which history.bash set first.
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__mylabskills_kube_prompt"
