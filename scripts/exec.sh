#!/usr/bin/env bash
# Drop into a bash shell inside the running container as botuser.
# Useful for ad-hoc inspection — env vars, file system, manually running win commands.
#
# Don't run mutating commands here unless you know what you're doing — bypasses
# all the Slack-side approval flows.

set -euo pipefail

exec docker exec -it slack-cc-ops bash
