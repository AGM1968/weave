#!/bin/bash
# resolve-refs.sh - Extract cross-references and suggest follow-up commands
#
# Usage:
#   resolve-refs.sh <file>           # Extract refs from file
#   resolve-refs.sh -t "some text"   # Extract refs from text
#   echo "text" | resolve-refs.sh    # Extract refs from stdin
#
# Outputs actionable commands, does NOT automatically fetch content.

set -e

MAX_REFS=10

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get input text
get_input() {
    if [ "$1" = "-t" ] && [ -n "$2" ]; then
        echo "$2"
    elif [ -n "$1" ] && [ -f "$1" ]; then
        cat "$1"
    elif [ ! -t 0 ]; then
        cat
    else
        echo "Usage: resolve-refs.sh <file> | -t \"text\" | stdin" >&2
        exit 1
    fi
}

INPUT=$(get_input "$@")

# Reference patterns and their handlers
declare -A REFS

# Extract Weave node IDs (format: wv-xxxx)
while IFS= read -r match; do
    [ -n "$match" ] && REFS["$match"]="wv show $match"
done < <(echo "$INPUT" | grep -oE '\bwv-[0-9a-fA-F]+\b' | head -n "$MAX_REFS")

# Extract legacy bead IDs (format: BEAD-xxx, MEM-xxx, BD-xxx)
while IFS= read -r match; do
    [ -n "$match" ] && REFS["$match"]="# Legacy bead: $match"
done < <(echo "$INPUT" | grep -oE '\b(BEAD|MEM|BD)-[0-9a-zA-Z]+\b' | head -n "$MAX_REFS")

# Extract GitHub issue references (gh-N or #N)
while IFS= read -r match; do
    if [ -n "$match" ]; then
        num=$(echo "$match" | grep -oE '[0-9]+')
        REFS["$match"]="gh issue view $num"
    fi
done < <(echo "$INPUT" | grep -oP '(gh-[0-9]+|(?<![a-zA-Z0-9])#[0-9]+)' | head -n "$MAX_REFS")

# Extract "See Note N" style references
while IFS= read -r match; do
    if [ -n "$match" ]; then
        note_id=$(echo "$match" | grep -oE '[0-9]+')
        REFS["$match"]="rg -n \"Note $note_id\" docs/"
    fi
done < <(echo "$INPUT" | grep -oiE 'see note [0-9]+' | head -n "$MAX_REFS")

# Extract ADR/RFC references
while IFS= read -r match; do
    if [ -n "$match" ]; then
        REFS["$match"]="rg -l \"$match\" docs/"
    fi
done < <(echo "$INPUT" | grep -oE '\b(ADR|RFC)-[0-9]+\b' | head -n "$MAX_REFS")

# Extract file path references (src/..., docs/..., scripts/...)
while IFS= read -r match; do
    if [ -n "$match" ]; then
        # Clean up the path (remove trailing punctuation)
        clean_path=$(echo "$match" | sed 's/[,.:;)]+$//')
        REFS["$clean_path"]="Read $clean_path"
    fi
done < <(echo "$INPUT" | grep -oE '\b(src|docs|scripts|tests)/[a-zA-Z0-9_/.-]+' | head -n "$MAX_REFS")

# Output results
if [ ${#REFS[@]} -eq 0 ]; then
    echo "No references found."
    exit 0
fi

echo -e "${CYAN}References found:${NC}"
echo ""

i=1
for ref in "${!REFS[@]}"; do
    cmd="${REFS[$ref]}"
    echo -e "  ${GREEN}$i.${NC} $ref"
    echo -e "     → ${YELLOW}$cmd${NC}"
    echo ""
    ((i++))
    
    if [ $i -gt $MAX_REFS ]; then
        echo "  ... (truncated at $MAX_REFS refs)"
        break
    fi
done

echo -e "${CYAN}Run commands manually to follow references.${NC}"
