#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# install.sh -- put this repo's hooks into .git/hooks.
#
# .git/hooks is not version controlled, so a fresh clone has none of this.
# The hooks live in tools/hooks so they survive a reclone; run this once per
# clone. Existing hooks are backed up rather than overwritten, because the
# commit-msg hook comes from ~/.config/git/template and is not ours to replace.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/.git/hooks"

[ -d "$DEST" ] || { echo "no .git/hooks at $DEST -- not a git checkout?"; exit 1; }

for src in "$ROOT"/tools/hooks/*; do
	name="$(basename "$src")"
	case "$name" in
		install.sh|*.md) continue ;;
	esac

	target="$DEST/$name"
	if [ -e "$target" ] && ! cmp -s "$src" "$target"; then
		cp "$target" "$target.backup"
		echo "backed up existing $name -> $name.backup"
	fi
	cp "$src" "$target"
	chmod +x "$target"
	echo "installed $name"
done
