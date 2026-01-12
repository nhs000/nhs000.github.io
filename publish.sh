#!/bin/bash
set -e

BLOG_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BLOG_DIR"

echo "Processing posts..."

# Backup original files, convert wikilinks, commit, then restore originals
# This keeps your source files with wikilinks intact in Obsidian

BACKUP_DIR=$(mktemp -d)
trap "rm -rf $BACKUP_DIR" EXIT

# Backup and convert each post
for file in _posts/*.md; do
    [ -f "$file" ] || continue

    # Backup original
    cp "$file" "$BACKUP_DIR/"

    # Convert [[Note|Display Text]] -> [Display Text](/note/)
    # Convert [[Note]] -> [Note](/note/)
    sed -i '' -E '
        s/\[\[([^]|]+)\|([^]]+)\]\]/[\2](\/\L\1\/)/g
        s/\[\[([^]]+)\]\]/[\1](\/\L\1\/)/g
    ' "$file"

    echo "Processed: $file"
done

echo "Committing and pushing..."

git add -A
git commit -m "Update blog: $(date '+%Y-%m-%d %H:%M')" || echo "Nothing to commit"
git push origin master

# Restore original files with wikilinks
for file in "$BACKUP_DIR"/*.md; do
    [ -f "$file" ] || continue
    cp "$file" _posts/
done

echo "Done! Your blog will be live at https://nhs000.github.io/ in a few minutes."
echo "(Your local files still have wikilinks intact)"
