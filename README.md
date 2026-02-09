# Traveler's Codex Companion

Lightweight data collector for the [Traveler's Codex](https://travelerscodex.com) desktop app. Automatically syncs your character data, inventory, and auction house prices so the desktop app can give you personalized gold-making advice, gear recommendations, and cooldown tracking across all your characters.

## What It Collects

- **Character info** — name, class, race, level, faction, spec (auto-detected from talents)
- **Gold** — updated in real-time as you earn/spend
- **Bags & Bank** — full inventory with item IDs and stack counts (bank updates when you open the banker)
- **Equipment** — all 19 equipped item slots
- **Professions** — skill levels for all professions including cooking, fishing, and first aid
- **Cooldowns** — alchemy transmutes, tailoring cloth cooldowns, leatherworking timers
- **Auction House prices** — integrates with Auctionator to export full price history (21 days)

## Installation

1. Download the latest release or clone this repo
2. Copy the `TravelersCodexCompanion` folder to your WoW AddOns directory:
   - **Windows**: `C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\`
   - **macOS**: `/Applications/World of Warcraft/_anniversary_/Interface/AddOns/`
3. Restart WoW or type `/reload`

Or install via [CurseForge](https://www.curseforge.com/wow/addons) using the CurseForge app.

## How It Works

1. Install the addon and log into WoW
2. Your character data syncs automatically on login, logout, and whenever bags/equipment/gold change
3. The [Traveler's Codex](https://travelerscodex.com) desktop app reads the SavedVariables file and updates in real-time

For auction house prices:
1. Open the AH and run a **Full Scan** in Auctionator
2. Prices auto-export when the scan completes
3. Type `/reload` or log out to save

## Slash Commands

- `/tcodex` — Show sync status summary
- `/tcodex scan` — Manually export Auctionator's price database
- `/tcodex clear` — Clear AH price data and start fresh
- `/tcodex help` — Show all commands

Also responds to `/tcx` and `/travelerscodex`.

## Supported Price Addons

- **Auctionator** (recommended) — full database scanning with price history
- **TradeSkillMaster (TSM)** — enriches data with market value, sale rates, and regional averages
- **Auc-Advanced** — fallback pricing source

The addon works without any price addon installed, but Auctionator is recommended for full AH data.

## Privacy

All data stays local on your machine in WoW's SavedVariables folder. Nothing is sent to any server. The desktop app reads the file directly from your WoW installation.

## Requirements

- WoW TBC Classic / Classic Anniversary (Interface 20504)
- [Traveler's Codex desktop app](https://travelerscodex.com) to view and use the collected data
- Auctionator (optional, for AH price data)

## License

MIT
