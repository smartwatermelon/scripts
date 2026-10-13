#!/usr/bin/env bash
set -euo pipefail
# Run allup on all local-macs hosts at once, one tmux pane each.
# Usage: allup-fleet [-d (don't attach)] [command (default: allup)]

detach=false
if [[ "${1:-}" == "-d" ]]; then
  detach=true
  shift
fi
cmd="${*:-allup}"

host_list="$("${LOCAL_MACS:-local-macs}")" || {
  echo "allup-fleet: local-macs failed" >&2
  exit 1
}
hosts=()
while IFS= read -r host; do
  [[ -n "${host}" ]] && hosts+=("${host}")
done <<<"${host_list}"

if ((${#hosts[@]} == 0)); then
  echo "allup-fleet: local-macs found no hosts" >&2
  exit 1
fi

# ssh -t keeps allup interactive (no -t: casks, macOS updates skipped). bash -lic loads the env that defines allup.
printf -v remote 'bash -lic %q' "${cmd}"

ssh_cmds=()
for host in "${hosts[@]}"; do
  printf -v ssh_cmd 'ssh -t %q %q' "${host}.local" "${remote}"
  ssh_cmds+=("${ssh_cmd}")
done

# Start on a placeholder so remain-on-exit is on before any ssh can exit.
# Inside tmux, add a window rather than nest a session.
placeholder="sleep 86400"
if [[ -n "${TMUX:-}" ]]; then
  window="$(tmux new-window -d -P -F '#{window_id}' -n allup "${placeholder}")"
else
  session="allup-fleet"
  if tmux has-session -t "=${session}" 2>/dev/null; then
    echo "allup-fleet: tmux session '${session}' already exists; attach with: tmux attach -t ${session}" >&2
    exit 1
  fi
  window="$(tmux new-session -d -P -F '#{window_id}' -s "${session}" -n allup "${placeholder}")"
fi
tmux set-option -w -t "${window}" remain-on-exit on
tmux set-option -w -t "${window}" pane-border-status top
tmux set-option -w -t "${window}" pane-border-format ' #{@host} '
tmux set-option -p -t "${window}" @host "${hosts[0]}"
tmux respawn-pane -k -t "${window}" "${ssh_cmds[0]}"

for ((i = 1; i < ${#hosts[@]}; i += 1)); do
  pane="$(tmux split-window -d -P -F '#{pane_id}' -t "${window}" "${ssh_cmds[i]}")"
  tmux set-option -p -t "${pane}" @host "${hosts[i]}"
  # Re-tile after each split so the window never runs out of room for the next.
  tmux select-layout -t "${window}" tiled
done

if [[ "${detach}" == true ]]; then
  echo "allup-fleet: started ${#hosts[@]} hosts in tmux window ${window}"
elif [[ -n "${TMUX:-}" ]]; then
  tmux select-window -t "${window}"
else
  tmux attach-session -t "=${session}"
fi
