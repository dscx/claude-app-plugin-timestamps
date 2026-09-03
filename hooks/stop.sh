#!/bin/sh
# claude-timestamps — Stop.
#
# Emits one single-line systemMessage per turn. The transcript renderer prefixes
# it per line as "Stop says: <stamp>", which is why the stamp must never contain
# a newline.
#
# Stop is the dangerous event. Exit status 2 on Stop means "do not stop" and
# turns the agent into an infinite loop; a bash syntax error exits 2 all by
# itself. Hence: no errexit, one exit path, and the real work quarantined in a
# command substitution whose failure can only produce an empty string.

umask 077

IN=$(cat)

TS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$TS_LIB" ] && . "$TS_LIB"

ts_stop_main() {
	ts_init

	# Rule 10: when the host reports that a Stop hook is already active for this
	# turn, do nothing at all. Re-entering here is how loops start.
	json_field stop_hook_active
	[ "$JF" = true ] && return 0

	json_field session_id
	ts_paths "$JF"

	json_field prompt_id
	sanitize_id "$JF"
	PROMPT_ID=$SID_OUT

	now_parts
	[ "$EPOCH_MS" != 0 ] || return 0

	# Turn duration, from our own one-line sidecar. The transcript is never read.
	ELAPSED=""
	ts_read_turn
	if [ -n "$TURN_MS" ] && [ "$TURN_PID" = "$PROMPT_ID" ] && [ "$EPOCH_MS" -ge "$TURN_MS" ]; then
		ELAPSED=$((EPOCH_MS - TURN_MS))
	fi

	if [ "$LOG" = 1 ]; then
		if [ -n "$ELAPSED" ]; then
			state_write "$TS_LOG_F" \
				"{\"t\":\"turn_end\",\"session_id\":\"$SID\",\"prompt_id\":\"$PROMPT_ID\",\"epoch_ms\":$EPOCH_MS,\"clock\":\"$CLOCK\",\"duration_ms\":$ELAPSED}"
		else
			state_write "$TS_LOG_F" \
				"{\"t\":\"turn_end\",\"session_id\":\"$SID\",\"prompt_id\":\"$PROMPT_ID\",\"epoch_ms\":$EPOCH_MS,\"clock\":\"$CLOCK\"}"
		fi
	fi

	# MODE=inline stamps via the model itself, MODE=off stamps not at all.
	# Either way Stop stays silent and only the log is written.
	[ "$MODE" = notice ] || return 0

	case "$FORMAT" in
		iso)
			STAMP=$ISO
			;;
		relative)
			STAMP=""
			ts_read_meta
			if [ -n "$META_MS" ] && [ "$EPOCH_MS" -ge "$META_MS" ]; then
				ts_dur $((EPOCH_MS - META_MS))
				[ -n "$DUR" ] && STAMP="+$DUR"
			fi
			[ -n "$STAMP" ] || STAMP=$CLOCK
			;;
		*)
			STAMP=$CLOCK
			;;
	esac

	[ -n "$STAMP" ] || return 0

	if [ "$SHOW_DURATION" = 1 ] && [ -n "$ELAPSED" ]; then
		ts_dur "$ELAPSED"
		[ -n "$DUR" ] && STAMP="$STAMP ($DUR)"
	fi

	emit "$STAMP"
	return 0
}

out=$( ts_stop_main 2>/dev/null ) || out=""
case "$out" in
	*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
