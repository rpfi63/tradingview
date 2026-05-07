#!/usr/bin/env bash
# Morning Brief Script — startet TradingView falls nötig und erstellt Obsidian-Notiz
# Manueller Start: bash scripts/morning_brief.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="/Users/rpfi/Library/Mobile Documents/iCloud~md~obsidian/Documents/Rolf"
BRIEF_DIR="$VAULT_DIR/05 Daily Notes/BTC Morning Brief"
TODAY="$(date +%Y-%m-%d)"
OUTPUT_FILE="$BRIEF_DIR/$TODAY.md"

# CDP-Verbindung prüfen — TradingView starten falls nicht verbunden
STATUS=$(tv status 2>/dev/null || echo '{"cdp_connected":false}')
CDP_UP=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cdp_connected', False))" 2>/dev/null || echo "False")

if [ "$CDP_UP" != "True" ]; then
  echo "TradingView nicht verbunden — starte mit Debug-Port..."
  bash "$SCRIPT_DIR/launch_tv_debug_mac.sh" >/dev/null 2>&1 &
  for i in $(seq 1 30); do
    sleep 2
    CDP_UP=$(tv status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('cdp_connected', False))" 2>/dev/null || echo "False")
    [ "$CDP_UP" = "True" ] && break
    echo "  Warte auf CDP... ($i/30)"
  done
  if [ "$CDP_UP" != "True" ]; then
    echo "FEHLER: CDP nicht erreichbar nach 60s. TradingView manuell prüfen." >&2
    exit 1
  fi
  echo "CDP verbunden — warte 5s bis Chart geladen..."
  sleep 5
fi

echo "CDP verbunden. Führe Morning Brief aus..."

# --- Morning Brief ausführen und JSON speichern ---
BRIEF_JSON=$(tv brief 2>&1)

if ! echo "$BRIEF_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null; then
  echo "FEHLER beim Morning Brief:" >&2
  echo "$BRIEF_JSON" >&2
  exit 1
fi

# --- Daten extrahieren ---
extract() {
  echo "$BRIEF_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null || echo "N/A"
}

GENERATED_AT=$(extract "d['generated_at']")
SYMBOL=$(extract "d['symbols_scanned'][0]['symbol']")
CLOSE=$(extract "d['symbols_scanned'][0]['quote']['close']")
OPEN=$(extract "d['symbols_scanned'][0]['quote']['open']")
HIGH=$(extract "d['symbols_scanned'][0]['quote']['high']")
LOW=$(extract "d['symbols_scanned'][0]['quote']['low']")
VOLUME=$(extract "d['symbols_scanned'][0]['quote']['volume']")

# Indikatoren
WMA200=$(extract "d['symbols_scanned'][0]['indicators']['studies'][0]['values']['WMA 200 (Vays)']")
WMA50=$(extract "d['symbols_scanned'][0]['indicators']['studies'][0]['values']['WMA 50 (Vays)']")
SMA18=$(extract "d['symbols_scanned'][0]['indicators']['studies'][0]['values']['SMA 18 (Brandt)']")
SMA8=$(extract "d['symbols_scanned'][0]['indicators']['studies'][0]['values']['SMA 8 (Brandt)']")

# Bias-Logik in Python
BIAS_RESULT=$(python3 -c "
import json

close = $CLOSE
wma200_str = '$WMA200'.replace(',', '')
wma50_str  = '$WMA50'.replace(',', '')
sma8_str   = '$SMA8'.replace(',', '')
sma18_str  = '$SMA18'.replace(',', '')

try:
    wma200 = float(wma200_str)
    wma50  = float(wma50_str)
    sma8   = float(sma8_str)
    sma18  = float(sma18_str)
except:
    print('NEUTRAL|Indikator-Parsing fehlgeschlagen')
    exit()

bulls = []
bears = []

if close > wma200:
    bulls.append('Über WMA 200 (Vays Makro-Bull)')
else:
    bears.append('Unter WMA 200 (Vays Makro-Bear)')

if close < wma50:
    bears.append('Unter WMA 50 (Momentum schwach)')
else:
    bulls.append('Über WMA 50 (Momentum stark)')

if sma8 > sma18:
    bulls.append('8 SMA > 18 SMA (Brandt Uptrend)')
else:
    bears.append('8 SMA < 18 SMA (Brandt Downtrend)')

mid = (wma200 + wma50) / 2
if wma200 < close < wma50:
    in_range = True
else:
    in_range = False

if len(bulls) > len(bears):
    bias = 'BULLISH'
elif len(bears) > len(bulls):
    bias = 'BEARISH'
else:
    bias = 'NEUTRAL'

bull_str = '; '.join(bulls) if bulls else 'keine'
bear_str = '; '.join(bears) if bears else 'keine'
range_note = 'Preis in S/R-Range Mitte — nur Edges traden (DonAlt)' if in_range else ''
print(f'{bias}|{bull_str}|{bear_str}|{range_note}')
")

BIAS=$(echo "$BIAS_RESULT" | cut -d'|' -f1)
BULL_SIGNALS=$(echo "$BIAS_RESULT" | cut -d'|' -f2)
BEAR_SIGNALS=$(echo "$BIAS_RESULT" | cut -d'|' -f3)
RANGE_NOTE=$(echo "$BIAS_RESULT" | cut -d'|' -f4)

# Key Level und Watch
ABOVE_WMA200=$(python3 -c "print('yes' if $CLOSE > float('$WMA200'.replace(',','')) else 'no')" 2>/dev/null || echo "yes")
if [ "$BIAS" = "BULLISH" ]; then
  KEY_LEVEL="\$$WMA200 (WMA 200 Support)"
  WATCH="Weekly Close über \$$HIGH — bestätigt bullisches Momentum. WMA 200 halten."
elif [ "$BIAS" = "BEARISH" ] && [ "$ABOVE_WMA200" = "no" ]; then
  KEY_LEVEL="\$$WMA200 (WMA 200 — verloren!)"
  WATCH="Ob Preis WMA 200 auf Weekly-Close-Basis zurückerobert."
elif [ "$BIAS" = "BEARISH" ]; then
  KEY_LEVEL="\$$WMA200 Support / \$$WMA50 Widerstand"
  WATCH="Ob Preis WMA 50 zurückerobert (\$$WMA50). WMA 200 als letzten Support nicht verlieren."
else
  KEY_LEVEL="\$$WMA200 Support / \$$WMA50 Widerstand"
  WATCH="Ausbruch aus der S/R-Range abwarten — nur Edges traden."
fi

# --- Markdown-Datei schreiben ---
mkdir -p "$BRIEF_DIR"

cat > "$OUTPUT_FILE" << MARKDOWN
---
tags:
  - morning-brief
  - btc
  - trading
date: $TODAY
symbol: $SYMBOL
bias: $BIAS
status: aktiv
---

# BTC Morning Brief — $TODAY

> Generiert: $GENERATED_AT | Strategie: Vays + Brandt + DonAlt (Weekly HTF)

## Marktdaten (Weekly)

| | |
|---|---|
| **Preis** | \$$CLOSE |
| Open | \$$OPEN |
| High | \$$HIGH |
| Low | \$$LOW |
| Volume | $VOLUME BTC |

## Indikatoren

| Indikator | Wert | Status |
|---|---|---|
| WMA 200 (Vays Makro) | \$$WMA200 | $([ "$(echo "$CLOSE > $(echo $WMA200 | tr -d ',')" | bc -l 2>/dev/null || echo 0)" = "1" ] && echo "✅ Preis darüber" || echo "❌ Preis darunter") |
| WMA 50 (Vays Momentum) | \$$WMA50 | $([ "$(echo "$CLOSE > $(echo $WMA50 | tr -d ',')" | bc -l 2>/dev/null || echo 0)" = "1" ] && echo "✅ Preis darüber" || echo "⚠️ Preis darunter") |
| SMA 18 (Brandt) | \$$SMA18 | — |
| SMA 8 (Brandt) | \$$SMA8 | $(python3 -c "print('✅ 8 > 18 (Uptrend)' if float('$SMA8'.replace(',','')) > float('$SMA18'.replace(',','')) else '❌ 8 < 18 (Downtrend)')" 2>/dev/null || echo "—") |

## Session Bias

**$SYMBOL | BIAS: $BIAS**

**Bullische Signale:** $BULL_SIGNALS

**Bearische Signale:** $BEAR_SIGNALS

$([ -n "$RANGE_NOTE" ] && echo "**Achtung:** $RANGE_NOTE" || echo "")

**Key Level:** $KEY_LEVEL

**Watch:** $WATCH

## Risk Rules

- Invalidation vor Eintrag definieren
- Positionsgrösse nach Stop-Distanz
- Nicht chassen — Setup kommen lassen
- Weekly Close abwarten (Vays: nie intrabar handeln)

---
*[[02 Projekte/tradingview/README|TradingView MCP Projekt]]*
MARKDOWN

echo ""
echo "Morning Brief erstellt: $OUTPUT_FILE"
echo "Bias: $BIAS | Preis: \$$CLOSE | WMA200: \$$WMA200"
