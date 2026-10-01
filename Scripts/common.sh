# Shared by the release scripts: where things are and what version this is.
# Sourced, not run.
set -eu -o pipefail

PROJECT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
OUT="$PROJECT/build"
APP="$OUT/MyHub.app"
# shellcheck source=version
. "$PROJECT/Scripts/version"

step() { printf '\033[1m» %s\033[0m\n' "$*"; }
