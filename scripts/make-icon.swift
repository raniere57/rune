#!/usr/bin/env swift
//
// Generates MenuAgent's app icon as an .icns.
//
// Drawn in code rather than committed as binary art: the mark is a handful of
// strokes, so a generator keeps the repo text-only and lets the palette be
// tuned by editing constants instead of round-tripping through a design tool.
//
// Mark: the Elder Futhark rune Algiz (ᛉ) — a stem with two raised arms. Chosen
// because the project is called `rune`, it is radially simple enough to stay
// legible at 16pt, and it reads as a distinct silhouette rather than yet
// another chat bubble or sparkle.
//
// Usage: swift scripts/make-icon.swift [output.icns]

import AppKit
import Foundation

// MARK: - Palette

let backgroundTop = NSColor(srgbRed: 0.42, green: 0.24, blue: 0.86, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.09, green: 0.06, blue: 0.22, alpha: 1)
let markColor = NSColor(srgbRed: 0.97, green: 0.96, blue: 1.00, alpha: 1)
let glowColor = NSColor(srgbRed: 0.62, green: 0.44, blue: 1.00, alpha: 1)

// MARK: - Drawing

/// Apple's icon grid keeps the art inside ~82% of the canvas.
let artInset: CGFloat = 0.09
/// Continuous-corner radius ratio matching the macOS app icon shape.
let cornerRatio: CGFloat = 0.2237

func drawIcon(size: CGFloat) -> NSImage {
	let image = NSImage(size: NSSize(width: size, height: size))
	image.lockFocus()
	defer { image.unlockFocus() }

	guard let context = NSGraphicsContext.current?.cgContext else { return image }
	context.setShouldAntialias(true)
	context.interpolationQuality = .high

	let inset = size * artInset
	let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
	let radius = plate.width * cornerRatio
	let platePath = CGPath(
		roundedRect: plate,
		cornerWidth: radius,
		cornerHeight: radius,
		transform: nil
	)

	// Base plate: vertical gradient, dark at the bottom so the mark reads as lit.
	context.saveGState()
	context.addPath(platePath)
	context.clip()
	let gradient = CGGradient(
		colorsSpace: CGColorSpaceCreateDeviceRGB(),
		colors: [backgroundBottom.cgColor, backgroundTop.cgColor] as CFArray,
		locations: [0, 1]
	)!
	context.drawLinearGradient(
		gradient,
		start: CGPoint(x: plate.midX, y: plate.minY),
		end: CGPoint(x: plate.midX, y: plate.maxY),
		options: []
	)

	// Off-centre highlight so the plate has a light source instead of reading flat.
	let highlight = CGGradient(
		colorsSpace: CGColorSpaceCreateDeviceRGB(),
		colors: [
			glowColor.withAlphaComponent(0.55).cgColor,
			glowColor.withAlphaComponent(0).cgColor,
		] as CFArray,
		locations: [0, 1]
	)!
	context.drawRadialGradient(
		highlight,
		startCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.22),
		startRadius: 0,
		endCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.22),
		endRadius: plate.width * 0.72,
		options: []
	)
	context.restoreGState()

	// Hairline rim: separates the icon from a dark Dock background.
	context.saveGState()
	context.addPath(platePath)
	context.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
	context.setLineWidth(max(1, size * 0.006))
	context.strokePath()
	context.restoreGState()

	// The Algiz mark.
	let markPath = algizPath(in: plate)
	let stroke = plate.width * 0.072

	context.saveGState()
	context.setLineWidth(stroke)
	context.setLineCap(.round)
	context.setLineJoin(.round)
	// Glow first, then the solid stroke on top, so the mark sits in the light
	// rather than on it.
	context.setShadow(
		offset: .zero,
		blur: plate.width * 0.10,
		color: glowColor.withAlphaComponent(0.85).cgColor
	)
	context.addPath(markPath)
	context.setStrokeColor(markColor.cgColor)
	context.strokePath()

	context.setShadow(offset: .zero, blur: 0, color: nil)
	context.addPath(markPath)
	context.setStrokeColor(markColor.cgColor)
	context.strokePath()
	context.restoreGState()

	return image
}

/// Algiz: a full-height stem with two arms rising from just below centre.
func algizPath(in rect: CGRect) -> CGPath {
	let path = CGMutablePath()
	let width = rect.width
	let centerX = rect.midX

	let top = rect.minY + rect.height * 0.755
	let bottom = rect.minY + rect.height * 0.235
	let fork = rect.minY + rect.height * 0.435
	let spread = width * 0.185

	path.move(to: CGPoint(x: centerX, y: bottom))
	path.addLine(to: CGPoint(x: centerX, y: top))

	path.move(to: CGPoint(x: centerX - spread, y: top))
	path.addLine(to: CGPoint(x: centerX, y: fork))
	path.addLine(to: CGPoint(x: centerX + spread, y: top))

	return path
}

// MARK: - Emission

func png(_ image: NSImage, pixels: Int) -> Data {
	let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: pixels,
		pixelsHigh: pixels,
		bitsPerSample: 8,
		samplesPerPixel: 4,
		hasAlpha: true,
		isPlanar: false,
		colorSpaceName: .deviceRGB,
		bytesPerRow: 0,
		bitsPerPixel: 0
	)!
	rep.size = NSSize(width: pixels, height: pixels)

	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	image.draw(
		in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
		from: .zero,
		operation: .sourceOver,
		fraction: 1
	)
	NSGraphicsContext.restoreGraphicsState()

	return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1
	? URL(fileURLWithPath: CommandLine.arguments[1])
	: URL(fileURLWithPath: "build/MenuAgent.icns")

let iconset = FileManager.default.temporaryDirectory
	.appendingPathComponent("MenuAgent-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// (point size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

for (points, scale) in variants {
	let pixels = points * scale
	// Rendered at its final pixel size rather than downscaled from 1024, so the
	// stroke weight stays crisp at 16pt.
	let image = drawIcon(size: CGFloat(pixels))
	let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
	try png(image, pixels: pixels).write(to: iconset.appendingPathComponent(name))
}

try? FileManager.default.createDirectory(
	at: output.deletingLastPathComponent(),
	withIntermediateDirectories: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
	FileHandle.standardError.write(Data("iconutil failed\n".utf8))
	exit(1)
}

// A standalone preview, handy for eyeballing the mark without mounting the app.
try png(drawIcon(size: 1024), pixels: 1024)
	.write(to: output.deletingPathExtension().appendingPathExtension("png"))

print("wrote \(output.path)")
