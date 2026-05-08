# How Many Mobs

A World of Warcraft: Classic Era addon designed for **grinding** - tracks how many mobs you need to kill to level up.

## v1.0 — Feature Highlights

- ✨ **3-mob rolling efficiency average** — stable, consistent efficiency ratings (no more wild swings)
- 📊 **Confidence ranges on mob counter** — see ±variance (e.g., "10 ± 2 mobs") once you have 3+ kills
- 🎯 **Weighted XP averaging** — recent kills matter more, reflects your improving performance at a grind spot
- 🎪 **Median-based kill time** — outlier filtering removes one-shots and AFK delays for accurate time estimates
- 🛡️ **Player-only kill credit** — only counts mobs you (or your group) actually damaged, not nearby players' kills
- 💤 **Rested XP aware** — stores base XP separately so predictions stay accurate when your rested bonus expires

## What is Grinding?

In World of Warcraft, **grinding** is the process of repeatedly killing mobs (enemies) of a similar level to gain experience points and level up your character. It's a straightforward, mechanical approach to leveling where you:
1. Find mobs at or near your level
2. Kill them repeatedly in the same area
3. Gain steady, consistent XP until you level up

This addon is specifically built to optimize your grinding sessions by showing you exactly how much longer you need to grind.

## Features

- **Mob Counter**: Automatically calculates how many more mobs you need to kill at your current grinding rate to reach the next level
  - Shows **confidence range** (±N) based on XP variance once you've killed 3+ mobs
  - Uses **weighted rolling average** - recent kills are weighted heavier (reflects learning/gear improvements)
  
- **Smart Efficiency Rating**: Shows you how efficient your current mob choice is for grinding
  - **3-mob rolling average** for stable, consistent readings (no wild swings)
  - Color-coded: green=optimal (80%+), yellow=good (50-79%), orange=slow (1-49%), red=gray mobs (0%)
  - Updated in real-time as you grind
  
- **Session Statistics**: Tracks kills per hour and XP gain per hour during your grinding session
  - Measures your actual grinding performance
  - Uses weighted averages so recent performance is more accurate
  
- **Outlier Detection**: Kill time averaging uses median + outlier filtering
  - Ignores lucky one-shots or AFK delays
  - Provides more accurate "time to level" estimates
  
- **Minimap Button**: Quick access to grinding stats with a convenient minimap button
  
- **Drag-and-Drop UI**: Move the display frame and minimap button wherever you want
  
- **Real-time Tracking**: Updates instantly as you grind and gain experience from kills
  
- **Cross-Level Data**: Preserves last 10 kills from previous level (for future level-by-level analysis)

## Installation

1. Extract the `HowManyMobs` folder to your WoW Classic Era AddOns directory:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\`
   - macOS: `/Applications/World of Warcraft/_classic_era_/Interface/AddOns/`

2. Restart World of Warcraft or reload the UI (`/reload`)

3. Make sure the addon is enabled in the AddOns list at the character select screen

## Usage

### Minimap Button
- Left-click the minimap button to toggle the main information display
- Right-click to open the options menu (toggle display lines, lock frame, reset data)
- Drag the button to reposition it on your minimap

### Main Window
The addon displays grinding-specific stats:
- **Mobs Needed**: Exactly how many more kills at your current grinding rate are needed to level
- **Last Killed**: The mob you just killed (helps verify you're grinding the right mob)
- **Estimated Time**: How long your current grind will take at your observed pace
- **Efficiency**: Whether this mob choice is a good grind spot for your level (green = excellent, yellow = okay, orange = slow)

## How It Works

This addon is optimized for your grinding sessions. It monitors your combat log to:
1. Detect when you kill a mob during your grind
2. Track the real experience gained from that kill
3. Calculate how many kills at your current rate are needed to reach the next level
4. Display session statistics (XP/hr, kills/hr) to measure your grinding efficiency
5. Estimate time to level based on your actual grinding performance

The addon learns from your grinding pace and adjusts estimates as you continue.

## Understanding Efficiency

**Efficiency Rating** shows you how optimal your current mob choice is for your level (0-100%).

### How It's Calculated

The addon compares the XP you gain from your current mob to the maximum XP you could get from a mob at your exact level:

```
Efficiency = (XP from current mob / XP from same-level mob) × 100%
```

**Important**: Efficiency shows a **3-mob rolling average** instead of single-kill ratings. This means:
- You need at least 1 kill to start seeing efficiency
- After 3 kills, the display becomes a true average of your last 3 targets
- This eliminates wild swings when changing mob types
- Much better reflects your actual grinding trend

**Example:**
- Level 20 character grinds Level 20 mobs = **100% efficient**
- Kills 3 of them = rolling avg shows **100%**
- Then kills 1 Level 18 mob = rolling avg shows ~**83%** (average of 3 recent kills)
- Then finds 3 more Level 20 mobs = rolling avg climbs back to ~**100%**

### Color Coding

- **🟢 Green (80-100%)**: Excellent grind spot! Mobs are within 1-2 levels of you
- **🟡 Yellow (50-79%)**: Good grinding, but you could find higher-level mobs for faster leveling
- **🟠 Orange (1-49%)**: Poor efficiency - mobs are too low level. Find harder mobs to level faster
- **🔴 Red (0%)**: Gray mobs give no XP. Find mobs closer to your level

### Mob Counter Accuracy

The addon shows how many mobs you need to level: **"10 mobs to level up"**

After 3+ kills, you'll also see a **confidence range**: **"10 mobs to level up (±2)"**

This means:
- Best case (if XP variance is low): ~8 mobs
- Average case: 10 mobs
- Worst case (if XP variance is high): ~12 mobs

The ±range gets tighter as you kill more mobs (variance decreases = more confident prediction)

## Advanced Features Explained

### Weighted XP Averaging
The addon doesn't use simple averages. Instead, **recent kills get higher weight** than older kills:
- Weights run linearly from N (newest kill) down to 1 (oldest kill), where N = number of kills with real XP data (up to 10)
- With 3 kills tracked: newest = 3×, middle = 2×, oldest = 1×
- This reflects that you **improve at a grind spot** as you continue (better positioning, understanding mob patterns)
- Makes predictions more accurate over time

**Example**: If your last 3 kills gave 80, 85, 90 XP (90 being most recent):
- Simple average: 85 XP
- Weighted average: (90×3 + 85×2 + 80×1) / 6 = **87 XP**
- More likely accurate since you're getting faster at this spot

### Kill Time Averaging
The addon uses **median with outlier filtering** for time estimates:
- Calculates the median (middle value) of kill times, not average
- Removes extreme outliers (kill times >1.5x the median)
- Eliminates "lucky one-shots" or "AFK delays" from skewing estimates
- Provides realistic "time to level" calculations

**Example**: Kill times of 3, 4, 4, 5, 20 seconds
- Simple average: 7.2 seconds
- Median with outliers: 4 seconds (removes the 20s AFK delay)
- Much more realistic!

## Compatibility

- **World of Warcraft**: Classic Era (Season of Discovery and Vanilla)
- **Interface Version**: 11403

## Requirements

- World of Warcraft: Classic Era client
- No other addons required

## Tips for Effective Grinding

- **Grind consistent mobs**: Kill mobs that are all the same level for the most accurate predictions
- **Grind in one location**: Avoid switching mobs mid-grind for best results (spawn time consistency helps)
- **Let the addon learn**: The estimated time gets more accurate the longer you grind in a session
- **Monitor efficiency**: Use the efficiency rating to verify your mob choice is good for your level
- **Session stats matter**: Check your XP/hr to compare different grinding spots
- **Session resets on level**: When you level up, your stats reset for the new level so you can track that level's grind separately

## Troubleshooting

**Addon not showing?**
- Type `/reload` to reload your UI
- Check that the addon is enabled in your AddOns list

**Minimap button missing?**
- Reset its position by deleting the SavedVariables or repositioning it through the UI

**Display not updating?**
- Make sure you're actively killing mobs and gaining experience

## License

Free to use and modify for personal use.

---

Enjoy tracking your leveling journey!
