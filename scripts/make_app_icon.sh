#!/bin/zsh
# Draws the macOS app icon and writes every size the asset catalog needs.
# Run from the project folder: scripts/make_app_icon.sh
set -e
out=MeroTyperAI/Resources/Assets.xcassets/AppIcon.appiconset
work=$(mktemp -d)
cat > "$work/icon.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// macOS icon grid: an 824-point rounded square centered on a 1024 canvas, transparent outside.
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
context.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 0.05, green: 0.30, blue: 0.72, alpha: 1), CGColor(srgbRed: 0.00, green: 0.13, blue: 0.40, alpha: 1)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// Sound becomes text: four wave bars, then a crimson text cursor.
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let crimson = CGColor(srgbRed: 0.93, green: 0.14, blue: 0.27, alpha: 1)
let bars: [(height: CGFloat, color: CGColor, width: CGFloat)] = [(170, white, 64), (360, white, 64), (250, white, 64), (130, white, 64), (480, crimson, 40)]
let gap: CGFloat = 48
var x = (CGFloat(size) - (bars.reduce(0) { $0 + $1.width } + gap * CGFloat(bars.count - 1))) / 2
for bar in bars {
    let rect = CGRect(x: x, y: (CGFloat(size) - bar.height) / 2, width: bar.width, height: bar.height)
    context.setFillColor(bar.color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2, transform: nil))
    context.fillPath()
    x += bar.width + gap
}

let output = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(output, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
SWIFT
swift "$work/icon.swift" "$work/icon_1024.png"

images=()
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    name="icon_${points}x${points}@${scale}x.png"
    sips -z $pixels $pixels "$work/icon_1024.png" --out "$out/$name" > /dev/null
    images+=("    { \"filename\": \"$name\", \"idiom\": \"mac\", \"scale\": \"${scale}x\", \"size\": \"${points}x${points}\" }")
  done
done
{
  echo '{'
  echo '  "images": ['
  echo "${(j:,\n:)images}"
  echo '  ],'
  echo '  "info": { "author": "xcode", "version": 1 }'
  echo '}'
} > "$out/Contents.json"
rm -rf "$work"
