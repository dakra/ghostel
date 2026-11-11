#!/bin/sh
# Inline (main-screen) TUI shaped like an agent prompt: output grows above
# an input row holding the cursor, with a rule and a status row below it.
#
# usage: prompt-tui.sh TAG WAIT COUNT HOLD
#
# Draws the prompt, waits WAIT s, streams COUNT rows "TAG-N" one frame
# each, holds HOLD s, then erases itself and prints "TAG-done".

frame() {
    printf '\033[?2026h\r\033[J%b> \r\n--------\r\nstatus-%s\033[2A\r\033[2C\033[?2026l' "$2" "$1"
}

frame "$1" ''
sleep "$2"
i=1
while [ "$i" -le "$3" ]; do
    frame "$1" "$1-$i\r\n"
    sleep 0.1
    i=$((i + 1))
done
sleep "$4"
printf '\r\033[J%s-done\r\n' "$1"
