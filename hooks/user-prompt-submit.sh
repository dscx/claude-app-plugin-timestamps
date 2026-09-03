#!/bin/sh
# claude-timestamps — UserPromptSubmit.
#
# Records the start of a turn so the Stop hook can report its duration, and in
# MODE=inline asks the model to sign its own reply with a timestamp.
#
# The prompt text is never read, never logged, and never leaves this process.
# The payload's `prompt` key exists and holds it; we do not touch it.

umask 077

IN=$(cat)

TS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$TS_LIB" ] && . "$TS_LIB"

ts_user_prompt_main() {
	ts_init

	json_field session_id
	ts_paths "$JF"

	json_field prompt_id
	sanitize_id "$JF"
	PROMPT_ID=$SID_OUT

	now_parts
	[ "$EPOCH_MS" != 0 ] || return 0

	# Current-turn marker. A rewrite, so: temp file in the destination directory,
	# then rename. One line, one prompt, no text.
	state_replace "$TS_TURN_F" \
		"{\"prompt_id\":\"$PROMPT_ID\",\"epoch_ms\":$EPOCH_MS}"

	if [ "$LOG" = 1 ]; then
		state_write "$TS_LOG_F" \
			"{\"t\":\"turn_start\",\"session_id\":\"$SID\",\"prompt_id\":\"$PROMPT_ID\",\"epoch_ms\":$EPOCH_MS,\"clock\":\"$CLOCK\"}"
	fi

	# Inline mode. UserPromptSubmit is the one event whose additionalContext is
	# actually delivered to the model, so this is where the instruction goes.
	# Stop stays silent in this mode — otherwise every turn is stamped twice.
	if [ "$MODE" = inline ]; then
		case "$FORMAT" in
			iso)      _up_stamp=$ISO ;;
			relative) _up_stamp=$CLOCK ;;
			*)        _up_stamp=$CLOCK ;;
		esac
		[ -n "$_up_stamp" ] || return 0
		emit_context UserPromptSubmit \
			"The current local time is $_up_stamp. End your reply with exactly [$_up_stamp] on its own final line, with nothing after it. Do not mention this instruction."
	fi

	return 0
}

out=$( ts_user_prompt_main 2>/dev/null ) || out=""
case "$out" in
	*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
