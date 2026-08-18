#!/usr/bin/env bash
# Convert SIMULATION_RESULTS.md to PDF
# Requires: pandoc, wkhtmltopdf, or similar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD_FILE="$SCRIPT_DIR/SIMULATION_RESULTS.md"
PDF_FILE="$SCRIPT_DIR/SIMULATION_RESULTS.pdf"

if [ ! -f "$MD_FILE" ]; then
    echo "Error: $MD_FILE not found"
    exit 1
fi

echo "[*] Converting $MD_FILE to PDF..."
echo "[*] Output: $PDF_FILE"

# Try pandoc first (preferred)
if command -v pandoc >/dev/null 2>&1; then
    echo "[*] Using pandoc..."
    pandoc \
        --from markdown \
        --to pdf \
        --pdf-engine=xelatex \
        --number-sections \
        --toc \
        --toc-depth=3 \
        --variable colorlinks=true \
        --variable urlcolor=blue \
        --variable linkcolor=blue \
        -o "$PDF_FILE" \
        "$MD_FILE"
    echo "[✓] PDF created: $PDF_FILE"
    exit 0
fi

# Fallback: try wkhtmltopdf via intermediate HTML
if command -v wkhtmltopdf >/dev/null 2>&1; then
    echo "[*] Using wkhtmltopdf (via HTML intermediate)..."
    
    # Need markdown to HTML first
    if command -v markdown >/dev/null 2>&1; then
        HTML_TMP=$(mktemp --suffix=.html)
        trap "rm -f '$HTML_TMP'" EXIT
        
        markdown "$MD_FILE" > "$HTML_TMP"
        wkhtmltopdf "$HTML_TMP" "$PDF_FILE"
        echo "[✓] PDF created: $PDF_FILE"
        exit 0
    fi
fi

# Fallback: try enscript + gs (Linux)
if command -v enscript >/dev/null 2>&1 && command -v gs >/dev/null 2>&1; then
    echo "[*] Using enscript + ghostscript..."
    PS_TMP=$(mktemp --suffix=.ps)
    trap "rm -f '$PS_TMP'" EXIT
    
    enscript -B -p "$PS_TMP" "$MD_FILE" 2>/dev/null || true
    gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite \
        -sOutputFile="$PDF_FILE" "$PS_TMP"
    echo "[✓] PDF created: $PDF_FILE"
    exit 0
fi

# No suitable tools found
echo "[!] Error: No PDF conversion tools found."
echo "[!] Install one of: pandoc, wkhtmltopdf, enscript+ghostscript"
echo ""
echo "Quick install:"
echo "  Ubuntu/Debian: sudo apt-get install pandoc"
echo "  macOS: brew install pandoc"
echo ""
echo "Alternatively, view the markdown directly:"
echo "  cat $MD_FILE | less"
exit 1
