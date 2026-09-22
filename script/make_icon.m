#import <Cocoa/Cocoa.h>
int main(int argc,char **argv){@autoreleasepool{
    NSString *output=@(argv[1]);[NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
    for(NSNumber *size in @[@16,@32,@128,@256,@512])for(int scale=1;scale<=2;scale++){
        int pixels=size.intValue*scale;NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];[NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=context;
        NSAffineTransform *t=[NSAffineTransform transform];[t scaleBy:pixels/1024.0];[t concat];
        [[NSColor colorWithRed:.12 green:.16 blue:.16 alpha:1] setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(46,46,932,932) xRadius:216 yRadius:216] fill];
        NSBezierPath *mark=[NSBezierPath bezierPath];[mark moveToPoint:NSMakePoint(340,746)];[mark lineToPoint:NSMakePoint(340,304)];[mark lineToPoint:NSMakePoint(690,304)];mark.lineWidth=94;mark.lineCapStyle=NSLineCapStyleRound;mark.lineJoinStyle=NSLineJoinStyleRound;[[NSColor colorWithRed:.89 green:.95 blue:.92 alpha:1] setStroke];[mark stroke];
        NSBezierPath *leaf=[NSBezierPath bezierPath];[leaf moveToPoint:NSMakePoint(490,490)];[leaf curveToPoint:NSMakePoint(746,746) controlPoint1:NSMakePoint(470,680) controlPoint2:NSMakePoint(606,746)];[leaf curveToPoint:NSMakePoint(490,490) controlPoint1:NSMakePoint(756,568) controlPoint2:NSMakePoint(644,472)];[[NSColor colorWithRed:.56 green:.78 blue:.66 alpha:1] setFill];[leaf fill];
        [NSGraphicsContext restoreGraphicsState];NSString *name=[NSString stringWithFormat:@"icon_%@x%@%@.png",size,size,scale==2?@"@2x":@""];[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES];
    }return 0;
}}
