#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <input-png> <opaque-output-png>" >&2
  exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Draw losslessly at native dimensions onto an opaque black RGB canvas.
xcrun swift - "$1" "$2" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(
          data: nil, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { fatalError("Cannot decode or flatten screenshot") }
let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
context.fill(bounds)
context.draw(image, in: bounds)
guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot encode opaque screenshot") }
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write opaque screenshot") }
SWIFT
