#!/usr/bin/env bash
# Test OSC8 hyperlinks in the terminal
# Format: \e]8;;URI\aLABEL\e]8;;\a

link() {
  local uri="$1" label="$2"
  printf '\e]8;;%s\a%s\e]8;;\a' "$uri" "$label"
}

echo "Plain text (no link)"
echo -n "Basic link: "
link "https://example.com" "Example"
echo ""
echo ""
echo -n "Email link: "
link "mailto:test@example.com" "Email"
echo ""
echo ""
echo -n "File link: "
link "file:///etc/hosts" "/etc/hosts"
echo ""
echo ""
echo "Multiple links on one line:"
echo -n "  "; link "https://emacs.org" "Emacs"; echo -n "  "; link "https://github.com" "GitHub"; echo ""
echo ""
echo "Link with special chars:"
echo -n "  "; link "https://example.com/path?foo=bar&baz=qux" "Query params"
echo ""
