/* V150 unique icon source. Host macOS AppKit only; no external image assets.
 * Output at 120,180 and 1024 pixels. Icon clearly reads "IPA 150".
 */
import AppKit
import Foundation

func icon(_ side:Int, to path:String) throws {
    let size = NSSize(width:side,height:side)
    let image = NSImage(size:size,flipped:false) { rect in
        let background=NSBezierPath(roundedRect:rect.insetBy(dx:2,dy:2),
                                    xRadius:CGFloat(side)*0.18,
                                    yRadius:CGFloat(side)*0.18)
        NSColor(calibratedRed:0.24,green:0.08,blue:0.35,alpha:1).setFill()
        background.fill()
        let inset=CGFloat(side)*0.10
        let ring=NSBezierPath(roundedRect:rect.insetBy(dx:inset,dy:inset),
                              xRadius:CGFloat(side)*0.13,
                              yRadius:CGFloat(side)*0.13)
        ring.lineWidth=max(2,CGFloat(side)*0.025)
        NSColor(calibratedRed:0.95,green:0.55,blue:0.97,alpha:1).setStroke()
        ring.stroke()
        let style=NSMutableParagraphStyle()
        style.alignment = .center
        let top=NSAttributedString(string:"IPA",attributes:[
            .font: NSFont.systemFont(ofSize:CGFloat(side)*0.29,weight:.black),
            .foregroundColor:NSColor.white,.paragraphStyle:style])
        let bot=NSAttributedString(string:"150",attributes:[
            .font: NSFont.monospacedDigitSystemFont(ofSize:CGFloat(side)*0.30,weight:.heavy),
            .foregroundColor:NSColor(calibratedRed:0.99,green:0.78,blue:0.44,alpha:1),
            .paragraphStyle:style])
        top.draw(in:NSRect(x:0,y:CGFloat(side)*0.47,width:CGFloat(side),height:CGFloat(side)*0.36))
        bot.draw(in:NSRect(x:0,y:CGFloat(side)*0.15,width:CGFloat(side),height:CGFloat(side)*0.35))
        return true
    }
    guard let tiff=image.tiffRepresentation,
          let rep=NSBitmapImageRep(data:tiff),
          let png=rep.representation(using:.png,properties:[:]) else {
        throw NSError(domain:"V150_ICON",code:1)
    }
    try png.write(to:URL(fileURLWithPath:path))
}
guard CommandLine.arguments.count==2 else { fatalError("usage: icon <app-dir>") }
let folder=CommandLine.arguments[1]
try icon(120,to:folder+"/V150Icon60x60@2x.png")
try icon(180,to:folder+"/V150Icon60x60@3x.png")
try icon(1024,to:folder+"/V150Icon1024.png")
