![icon](https://github.com/testbild-media/Decklink-Multiviewer/blob/main/docs/icon_128.png)

# DecklinkMultiviewer

macOS 2x2 multiviewer application for Blackmagic DeckLink cards with integrated tally support via TSL 5.0, REST and WebSocket.

---

## Features

- 2x2 monitoring via DeckLink hardware
- OSC remote control support (window 1-4 + multiview + hide window) for e.g. Bitfocus Companion
- TSL 5.0 support (UDP & TCP)
- UMD / IMD label display
- Full tally support:
  - Program (Red)
  - Preview (Green)
  - Amber (Red + Green)  
- Low-latency rendering optimized for broadcast environments  

---

## Tally Support

### TSL 5.0

Fully implemented and tested.

- UDP and TCP supported  
- Handles vendor-specific variations  
- TXT, LH and RH evaluated using OR logic  
- Any RED state triggers Program tally  
- Supports RED, GREEN and AMBER states  

### REST API & WebSocket (Placeholder)

REST and WebSocket use the same JSON structure:
{
"program": [1],
"preview": [2]
}

Amber is created when the same input is present in both arrays:
{
"program": [3],
"preview": [3]
}

---

## Screenshots

| Multiviewer | Single View |
|-------------|---------------|
| ![Multiviewer](https://github.com/testbild-media/Decklink-Multiviewer/blob/main/docs/app-multiviewer.jpg) | ![Single Input](https://github.com/testbild-media/Decklink-Multiviewer/blob/main/docs/app-singleinput.jpg) |

| Settings |
|-------------|
| ![Settings](https://github.com/testbild-media/Decklink-Multiviewer/blob/main/docs/settings.jpg) |

---

## Requirements

- macOS Sequoia 15.7.5+ (only tested on Intel)
- Blackmagic Desktop Video 14.3+ installed 
- Blackmagic DeckLink SDK 14.3
- DeckLink compatible hardware  

---

## DeckLink SDK Setup

The DeckLink SDK sources must be available at: `/Library/DeckLinkSDK`

Copy the contents of: `Blackmagic DeckLink SDK 14.3\Mac\include` into `/Library/DeckLinkSDK`

---

## Build

Open the project in Xcode:
`Product → Build`

Create a standalone app:
`Product → Archive → Distribute App → Copy App`

---

## Notes
- App Sandbox must be disabled for DeckLink access  
- Hardened Runtime requires:
  - `Disable Library Validation` enabled  

---

## ToDo's
- testing on Macbook M1 2020
- long term tests on production

---

## License

This project is licensed under the MIT License – see the [LICENSE](LICENSE) file for details.
