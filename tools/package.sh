#!/usr/bin/env bash
# Build the release files of tremind and their checksum.
#
#   tools/package.sh
#
# Writes dist/tremind (the script, mode 755) and dist/tremind.sha256 (the line that "sha256sum -c"
# reads), and prints the sha256. Before that it checks that the script parses, that it starts with
# the expected shebang, that its version is a valid SemVer one, and that "tremind --version" prints
# it. On a tag (GITHUB_REF_TYPE=tag) the tag must be the version of the script, without "v".
set -euo pipefail

readonly name="tremind"

die() { printf 'package: %s\n' "$*" >&2; exit 1; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
    verify() { sha256sum -c "$1" >/dev/null; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
    verify() { shasum -a 256 -c "$1" >/dev/null; }
else
    die "sha256sum or shasum is required"
fi

[ -f "$name" ] || die "missing $name: run the script from a checkout of the repository"
[ "$(head -n 1 "$name")" = '#!/usr/bin/env bash' ] || die "$name must start with #!/usr/bin/env bash"
bash -n "$name" || die "$name does not parse"

version=$(sed -n 's/^readonly VERSION="\([^"]*\)"$/\1/p' "$name" | head -n 1)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "no valid version in $name: '$version'"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ "${GITHUB_REF_NAME:-}" != "$version" ]; then
    die "the tag ${GITHUB_REF_NAME:-} is not the version $version of $name"
fi

mkdir -p dist
install -m 0755 "$name" "dist/$name"
cmp -s "$name" "dist/$name" || die "the copy differs from $name"

# The file that is published must be the one that answers with its version.
shown=$("dist/$name" --version) || die "dist/$name --version failed"
[ "$shown" = "$name $version" ] || die "dist/$name --version says '$shown', expected '$name $version'"

sum=$(sha256 "dist/$name")
printf '%s  %s\n' "$sum" "$name" >"dist/$name.sha256"
(cd dist && verify "$name.sha256") || die "the checksum file does not match dist/$name"

printf '%s %s\n' "$name" "$version"
printf 'file:   dist/%s\n' "$name"
printf 'sha256: %s\n' "$sum"
