# CLI tools for the demo, for macOS or Linux (Homebrew / Linuxbrew).
#   brew bundle install --no-upgrade --file=Brewfile   (or: make brew)
#
# Homebrew installs each formula's current version and can't pin an arbitrary one.
# versions.env owns the pins and `make vendor` checks them. When a formula has moved
# past a pin, `make vendor` names the tool, and you install that version another way
# (the project's release binary into TOOLS_BIN, see docs/07-setup.md).
#
# Not covered here: a Docker engine (Docker Desktop, colima or your distro's docker),
# and curl and git, which the OS already ships.

tap "argoproj/tap"

# Cluster and GitOps (pinned in versions.env)
brew "kind"
brew "kubernetes-cli"                       # kubectl
brew "argoproj/tap/kubectl-argo-rollouts"   # the kubectl plugin
brew "argocd"
brew "helm"

# Policy, secrets scan and tests (pinned)
brew "conftest"
brew "gitleaks"
brew "bats-core"
brew "shellcheck"

# Recording (pinned; only for make record-* and make gif)
brew "asciinema"
brew "agg"

# Scripts (not pinned)
brew "gh"
brew "jq"
brew "yq"
brew "pv"
brew "uv"
brew "gettext"                              # envsubst
brew "flock" if OS.mac?                     # Linux has flock from util-linux
