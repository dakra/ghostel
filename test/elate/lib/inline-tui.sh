#!/bin/sh
# Inline (main-screen) TUI: output grows above an input row holding the
# cursor, with three static rows below it.
#
# usage: inline-tui.sh TAG COUNT
#
# Draws the input row "> in-TAG", waits 2 s, streams COUNT rows "TAG-N"
# one frame each, holds 2 s, then erases itself and prints "TAG-done".

frame() {
    printf '\033[?2026h\r\033[J%b> in-%s\r\nstatus-1\r\nstatus-2\r\nstatus-3\033[3A\r\033[8C\033[?2026l' "$2" "$1"
}

frame "$1" ''
sleep 2
i=1
while [ "$i" -le "$2" ]; do
    frame "$1" "$1-$i\r\n"
    sleep 0.05
    i=$((i + 1))
done
sleep 2
printf '\r\033[J%s-done\r\n' "$1"
