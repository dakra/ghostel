#!/bin/sh
# Remote half of `ghostel ssh': start the login shell with ghostel's
# shell integration injected for this session only.  Uses the same
# bootstrap shims as a local spawn (etc/shell/bootstrap), with
# EMACS_GHOSTEL_PATH pointing at the pushed copy.  Unrecognised login
# shells start plainly.
root=$HOME/.local/share/ghostel
export EMACS_GHOSTEL_PATH="$root"
shell=${SHELL:-/bin/sh}
case ${shell##*/} in
    bash)
        # POSIX mode makes bash read $ENV; inject.bash restores normal
        # mode, sources the profile chain and loads the integration.
        [ -n "${ENV:-}" ] && export GHOSTEL_BASH_ENV="$ENV"
        if [ -z "${HISTFILE:-}" ]; then
            export HISTFILE="$HOME/.bash_history" GHOSTEL_BASH_UNEXPORT_HISTFILE=1
        fi
        ENV=$root/etc/shell/bootstrap/bash/inject.bash GHOSTEL_BASH_INJECT=1 \
            exec "$shell" --posix -l
        ;;
    zsh)
        [ -n "${ZDOTDIR+x}" ] && export GHOSTEL_ZSH_ZDOTDIR="$ZDOTDIR"
        ZDOTDIR=$root/etc/shell/bootstrap/zsh exec "$shell" -l
        ;;
    fish|nu)
        # Both scan <entry>/fish/vendor_conf.d resp. <entry>/nushell/vendor/autoload.
        d=$root/etc/shell/bootstrap
        GHOSTEL_SHELL_INTEGRATION_XDG_DIR=$d \
            XDG_DATA_DIRS=$d:${XDG_DATA_DIRS:-/usr/local/share:/usr/share} \
            exec "$shell" -l
        ;;
    *)
        exec "$shell" -l
        ;;
esac
