# Third-party notices

Desks is licensed under the MIT License (see `LICENSE`). It adapts small parts of one open-source project and links one open-source library. Both are MIT licensed. Their notices are reproduced here.

## AeroSpace

- Project: https://github.com/nikitabobko/AeroSpace
- Used in: `Sources/DesksCore/Displays.swift` (bottom corner choice that avoids neighbour displays, park point with a 1 px sliver and the Zoom exception), `Sources/DesksCore/AXSupport.swift` (turning `AXEnhancedUserInterface` off around moves), `Sources/DesksCore/ParkingEngine.swift` (size, position, size order; show before park), `Sources/DesksCore/Focus.swift` (AXMain, AXRaise, then activate).

```
MIT License

Copyright (c) 2023 Nikita Bobko

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## KeyboardShortcuts

- Project: https://github.com/sindresorhus/KeyboardShortcuts
- Version: 2.4.0 (see `Package.resolved`). Used as a Swift package dependency and linked into the app. Its resource bundle (`KeyboardShortcuts_KeyboardShortcuts.bundle`) is copied into `Desks.app/Contents/Resources`.

```
MIT License

Copyright (c) Sindre Sorhus (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

No GPL code (FlashSpace and others) is included. Those projects were read for ideas only.
