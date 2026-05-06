# How Many Mobs

A World of Warcraft: Classic Era addon that tracks how many mobs you need to kill to level up.

## Features

- **Mob Counter**: Automatically calculates and displays how many mobs of the last type you killed you need to eliminate to reach the next level
- **Session Statistics**: Tracks kills and experience gained during your current session
- **Minimap Button**: Quick access to stats with a convenient minimap button
- **Drag-and-Drop UI**: Move the display frame and minimap button wherever you want
- **Automatic Calculation**: Updates in real-time as you gain experience from kills

## Installation

1. Extract the `HowManyMobs` folder to your WoW Classic Era AddOns directory:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\`
   - macOS: `/Applications/World of Warcraft/_classic_era_/Interface/AddOns/`

2. Restart World of Warcraft or reload the UI (`/reload`)

3. Make sure the addon is enabled in the AddOns list at the character select screen

## Usage

### Minimap Button
- Click the minimap button to toggle the main information display
- Right-click to close the window
- Drag the button to reposition it on your minimap

### Main Window
The addon displays:
- **Mobs Needed**: How many more kills like your last one are needed to level
- **Last Killed**: Information about the last mob you killed
- **Estimated Time**: Approximate time until you reach the next level (based on current session pace)

## How It Works

The addon monitors your combat log to:
1. Detect when you kill a mob
2. Calculate the experience gained from that kill
3. Determine how many kills at that rate are needed to reach the next level
4. Update the display with real-time statistics

## Compatibility

- **World of Warcraft**: Classic Era (Season of Discovery and Vanilla)
- **Interface Version**: 11403

## Requirements

- World of Warcraft: Classic Era client
- No other addons required

## Tips

- Grind mobs that give consistent experience for more accurate estimates
- The estimated time gets more accurate the longer your session runs
- Session statistics reset when you log out or change characters

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
