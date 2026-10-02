# Audio Book Reader

Reads PDF and EPUB files aloud with Indian voices and adjustable speed. It runs entirely in your browser; your books are never uploaded anywhere.

## Run it

Double-click `start.bat`. It starts a small local server (needs Python) and opens http://localhost:8000 in Microsoft Edge.

## Features

- Opens **PDF** and **EPUB** files (button or drag and drop)
- **Text to speech**, highlighting the current sentence and scrolling along
- **Speed** from 0.5× to 3×; changes apply straight away
- **Indian voices** listed first, with an "Indian voices only" filter
- Click any sentence to read from there; jump to chapters/pages from the sidebar
- Remembers your place in each book and your voice and speed settings
- Keyboard: `Space` play/pause, `←`/`→` previous/next sentence

## Indian voices

| Browser | Voices you get |
|---|---|
| Microsoft Edge (recommended) | Neerja, Prabhat (natural English-India), plus Hindi and other Indian languages |
| Chrome | Google हिन्दी, plus any Windows voices installed |

To add offline Windows voices (Heera, Ravi, Hemant, Kalpana): go to **Settings › Time & language › Speech › Add voices** and pick **English (India)** and/or **Hindi (India)**.

## Limitations

- Scanned PDFs (images only) have no text to read; they need OCR first.
- DRM-protected EPUBs can't be opened.
- Pausing restarts the current sentence when you resume.
