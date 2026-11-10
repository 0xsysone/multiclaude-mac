// Shifts the hue of a PNG (same drawing, another colour) with Core Image.
// usage: hue <in.png> <out.png> <degrees>
import Foundation
import CoreImage
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let degrees = Double(args[3]) else {
    FileHandle.standardError.write("usage: hue <in.png> <out.png> <degrees>\n".data(using: .utf8)!)
    exit(2)
}
guard let image = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let filter = CIFilter(name: "CIHueAdjust")!
filter.setValue(image, forKey: kCIInputImageKey)
filter.setValue(degrees * Double.pi / 180, forKey: kCIInputAngleKey)
let rep = NSBitmapImageRep(ciImage: filter.outputImage!)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
