#!/bin/sh
# claude-timestamps — MessageDisplay.
#
# One record per assistant message. This event's output is discarded by the
# host — it can never render anything — so this hook is log-only and prints
# nothing at all.
#
# The payload's `delta` field contains assistant message text. It is never
# written anywhere. Only its length is recorded, which is enough to tell an
# empty message from a real one without keeping a copy of the conversation on
# disk.

umask 077

IN=$(cat)

TS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$TS_LIB" ] && . "$TS_LIB"

ts_message_display_main() {
	ts_init

	[ "$LOG" = 1 ] || return 0

	json_field session_id
	ts_paths "$JF"

	json_field prompt_id
	sanitize_id "$JF"
	PROMPT_ID=$SID_OUT

	json_field turn_id
	sanitize_id "$JF"
	TURN_ID=$SID_OUT

	json_field message_id
	sanitize_id "$JF"
	MESSAGE_ID=$SID_OUT

	json_field index
	MSG_INDEX=$JF
	case "$MSG_INDEX" in
		''|*[!0-9]*) MSG_INDEX=-1 ;;
	esac

	json_field final
	case "$JF" in
		true) IS_FINAL=true ;;
		*)    IS_FINAL=false ;;
	esac

	# Length only. The text itself stops here — and on a large payload it never
	# enters the shell at all: ts_prepare_payload has already reduced the
	# payload to the fields above plus this one number. A length of -1 means
	# "not measurable here", not "empty".
	ts_delta_len

	now_parts
	[ "$EPOCH_MS" != 0 ] || return 0

	state_write "$TS_LOG_F" \
		"{\"t\":\"message\",\"session_id\":\"$SID\",\"prompt_id\":\"$PROMPT_ID\",\"turn_id\":\"$TURN_ID\",\"message_id\":\"$MESSAGE_ID\",\"index\":$MSG_INDEX,\"final\":$IS_FINAL,\"epoch_ms\":$EPOCH_MS,\"clock\":\"$CLOCK\",\"delta_len\":$DELTA_LEN}"

	return 0
}

out=$( ts_message_display_main 2>/dev/null ) || out=""
case "$out" in
	*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
