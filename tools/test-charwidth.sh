#!/usr/bin/env bash
# Visual double-width character verification.
#
# For each character type, a line of N chars is printed directly above
# a baseline of 2N ASCII dots.  If the terminal renders each char at
# exactly 2 columns the trailing | markers will be vertically aligned.
#
# Look at the output — nothing here can be verified programmatically.

RULER='+----+----+----+----+----+----+----+----+----+----+'
NUMS='1    5    10   15   20   25   30   35   40   45   50'

section() {
  printf '\n\e[1m%s\e[0m\n' "=== $1 ==="
  printf '%s\n' "$RULER"
  printf '%s\n' "$NUMS"
  echo
}

# pair LABEL CHARS DOTS
# Prints LABEL, then CHARS|, then DOTS| on the next line.
# DOTS should be exactly 2× as many characters as CHARS.
pair() {
  local label="$1" chars="$2" dots="$3"
  printf '  %-22s %s|\n' "$label" "$chars"
  printf '  %-22s %s|\n' "(ASCII baseline)" "$dots"
  echo
}

echo
echo 'Each test char type is shown above an ASCII dot baseline.'
echo 'The | at the end of each pair MUST be vertically aligned.'
echo 'Misalignment means that character type renders at the wrong width.'
echo

section "CJK ideographs  (10 chars → 20 cols)"
pair "10 CJK"       "的一了是我不在人们有"   "...................."
pair "10 hiragana"  "あいうえおかきくけこ"   "...................."
pair "10 katakana"  "アイウエオカキクケコ"   "...................."
pair "10 hangul"    "가나다라마바사아자차"   "...................."

section "Full-width Latin  (10 chars → 20 cols)"
pair "10 fw-Latin"  "ＡＢＣＤＥＦＧＨＩＪ"  "...................."
pair "10 fw-digits" "０１２３４５６７８９"   "...................."

section "Emoji  (10 chars → 20 cols)"
pair "10 faces"     "😀😃😄😁😆😅🤣😂🙂😉"   "...................."
pair "10 objects"   "🍎🍊🍋🍌🍇🍓🍒🍑🥭🍍"   "...................."
pair "10 symbols"   "⚽️🏀🏈⚾️🎾🏐🏉🎱🏓🏸"   "...................."
pair "10 signs"     "⚠️❗❕❓❔‼️⁉️〰️〽️✅"   "...................."

section "Emoji presentation sequences  (10 base chars + VS16 → 20 cols)"
pair "10 VS16"      "⚠️‼️⁉️〰️〽️©️®️™️♥️♠️"   "...................."

section "Emoji keycaps  (12 ASCII bases → 24 cols)"
pair "12 keycaps"   "#️⃣*️⃣0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣" "........................"

section "Emoji flags  (10 pairs of regional indicators → 20 cols)"
pair "10 flags"     "🇺🇸🇬🇧🇫🇷🇩🇪🇯🇵🇨🇳🇰🇷🇧🇷🇮🇳🇮🇹"   "...................."

section "Half-width katakana  (10 chars → 10 cols, single-width)"
pair "10 hw-kana"   "ｱｲｳｴｵｶｷｸｹｺ"              ".........."

section "ZWJ sequences  (each sequence = 1 glyph, typically 2 cols)"
echo '  These are renderer-defined — width varies. No fixed baseline.'
echo '  Check visually whether each glyph occupies ~2 columns.'
echo
printf '  👨‍💻 👩‍🔬 👨‍🍳 👩‍🎨 👨‍✈️\n'
printf '  👨‍👩‍👧  👨‍👩‍👧‍👦  👩‍👩‍👦  👨‍👨‍👧\n'
echo

section "Skin-tone modifier sequences  (10 chars → 20 cols)"
pair "10 skin-tone" "👋🏻👋🏼👋🏽👋🏾👋🏿👍🏻👍🏼👍🏽👍🏾👍🏿" "...................."

section "Combining diacritics  (10 base+combining → 10 cols, single-width)"
pair "10 combined"  "àèìòùáéíóú"                ".........."

printf '%s\n' "$RULER"
printf '%s\n' "$NUMS"
echo
