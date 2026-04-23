# Reusable Emacs 30.2 sandbox for reproducing package-vc-install bugs
# and anything else that needs a clean Emacs 30 environment.
#
# Build:  docker build -t ghostel-emacs30 docker/emacs30
# Run:    see docker/emacs30/README.md
FROM silex/emacs:30.2

# package-vc-install needs git; ca-certificates so HTTPS clones work.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Isolated per-session user-emacs-directory, so the repo mount under /repo
# is never touched by installed packages, caches, or autoloads.
ENV HOME=/home/tester
RUN useradd --create-home --shell /bin/bash tester
USER tester
WORKDIR /home/tester

# Default to an interactive shell — override with a specific command when
# automating (see test-package-vc.sh).
CMD ["/bin/bash"]
