#import "LTTheme.h"
#import <QuartzCore/QuartzCore.h>

static NSArray<NSString *> *Names(void) {
    return @[ @"Lavender", @"Ocean", @"Mint", @"Peach", @"Rose", @"Sand", @"Graphite" ];
}
NSArray<NSString *> *LTPaletteNames(void) {
    return Names();
}
NSColor *LTPaletteColor(NSString *name) {
    static NSDictionary<NSString *, NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      palette = @{
          @"Lavender" : [NSColor colorWithSRGBRed:.55 green:.47 blue:.95 alpha:1],
          @"Ocean" : [NSColor colorWithSRGBRed:.25 green:.55 blue:.95 alpha:1],
          @"Mint" : [NSColor colorWithSRGBRed:.20 green:.72 blue:.58 alpha:1],
          @"Peach" : [NSColor colorWithSRGBRed:.98 green:.55 blue:.40 alpha:1],
          @"Rose" : [NSColor colorWithSRGBRed:.93 green:.38 blue:.58 alpha:1],
          @"Sand" : [NSColor colorWithSRGBRed:.80 green:.66 blue:.40 alpha:1],
          @"Graphite" : [NSColor colorWithSRGBRed:.45 green:.48 blue:.55 alpha:1],
          @"Private" : [NSColor colorWithSRGBRed:.35 green:.25 blue:.65 alpha:1]
      };
    });
    return [name isKindOfClass:NSString.class] ? palette[name] : nil;
}
NSString *LTSpacePaletteName(NSDictionary *settings, NSString *spaceID, BOOL isPrivate) {
    if (isPrivate)
        return @"Private";
    NSDictionary *themes = settings[@"spaceThemes"];
    NSString *chosen = [themes isKindOfClass:NSDictionary.class] ? themes[spaceID] : nil;
    if ([chosen isKindOfClass:NSString.class] && [Names() containsObject:chosen])
        return chosen;
    // FNV-1a keeps the automatic color stable across launches and machines.
    uint32_t hash = 2166136261u;
    for (const char *c = (spaceID ?: @"").UTF8String; *c; c++)
        hash = (hash ^ (uint8_t)*c) * 16777619u;
    // Graphite is only used when chosen explicitly.
    return Names()[hash % (Names().count - 1)];
}
NSColor *LTSpaceTint(NSDictionary *settings, NSString *spaceID, BOOL isPrivate) {
    return LTPaletteColor(LTSpacePaletteName(settings, spaceID, isPrivate));
}
BOOL LTAppearanceIsDark(NSAppearance *appearance) {
    return [[appearance ?: NSApp.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqual:NSAppearanceNameDarkAqua];
}
NSArray<NSColor *> *LTBackdropColors(NSColor *tint, BOOL dark) {
    NSColor *base = [tint ?: LTPaletteColor(@"Graphite") colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat h, s, b, a;
    [base getHue:&h saturation:&s brightness:&b alpha:&a];
    NSColor *shifted = [NSColor colorWithColorSpace:NSColorSpace.sRGBColorSpace
                                                hue:fmod(h + .06, 1)
                                         saturation:s
                                         brightness:b
                                              alpha:1];
    NSColor *toward = dark ? [NSColor colorWithSRGBRed:.07 green:.07 blue:.08 alpha:1]
                           : [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1];
    return @[
        [base blendedColorWithFraction:dark ? .70 : .72 ofColor:toward] ?: toward,
        [shifted blendedColorWithFraction:dark ? .80 : .60 ofColor:toward] ?: toward
    ];
}
static void SetShadowPath(CALayer *layer, NSRect bounds, CGFloat radius) {
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        layer.shadowPath = nil;
        return;
    }
    radius = MIN(radius, MIN(bounds.size.width, bounds.size.height) / 2);
    CGPathRef path = CGPathCreateWithRoundedRect(bounds, radius, radius, NULL);
    layer.shadowPath = path;
    CGPathRelease(path);
}

@implementation LTBackdrop
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _drawsBackdrop = YES;
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}
- (CALayer *)makeBackingLayer {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.startPoint = CGPointMake(.2, 1);
    layer.endPoint = CGPointMake(.8, 0);
    layer.cornerCurve = kCACornerCurveContinuous;
    return layer;
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    [self applyStyle];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyStyle];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateShadowPath];
}
- (void)setTint:(NSColor *)tint {
    [self setTint:tint animated:NO];
}
- (void)setTint:(NSColor *)tint animated:(BOOL)animated {
    if (tint == _tint || [tint isEqual:_tint])
        return;
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    NSArray *from = layer.colors;
    _tint = tint;
    [self applyStyle];
    if (animated && from && self.window && (_drawsBackdrop || _floating) &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
        fade.fromValue = from;
        fade.toValue = layer.colors;
        fade.duration = .3;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [layer addAnimation:fade forKey:@"tint"];
    }
}
- (void)setDrawsBackdrop:(BOOL)drawsBackdrop {
    _drawsBackdrop = drawsBackdrop;
    [self applyStyle];
}
- (void)setFloating:(BOOL)floating {
    _floating = floating;
    [self applyStyle];
}
- (void)updateShadowPath {
    if (_floating)
        SetShadowPath(self.layer, self.bounds, 12);
    else
        self.layer.shadowPath = nil;
}
- (void)applyStyle {
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    if (![layer isKindOfClass:CAGradientLayer.class])
        return;
    BOOL dark = LTAppearanceIsDark(self.effectiveAppearance);
    if (_drawsBackdrop || _floating) {
        NSArray<NSColor *> *colors = LTBackdropColors(_tint, dark);
        layer.colors = @[ (id)colors[0].CGColor, (id)colors[1].CGColor ];
    } else
        layer.colors = @[ (id)NSColor.clearColor.CGColor, (id)NSColor.clearColor.CGColor ];
    layer.cornerRadius = _floating ? 12 : 0;
    layer.borderWidth = _floating ? 1 : 0;
    layer.borderColor = [NSColor colorWithWhite:1 alpha:dark ? .10 : .55].CGColor;
    layer.shadowColor = NSColor.blackColor.CGColor;
    layer.shadowOpacity = _floating ? (dark ? .5 : .2) : 0;
    layer.shadowRadius = 18;
    layer.shadowOffset = CGSizeMake(0, -6);
    [self updateShadowPath];
}
@end

@interface LTCardClip : NSView
@end
@implementation LTCardClip
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    BOOL dark = LTAppearanceIsDark(self.effectiveAppearance);
    self.layer.backgroundColor = NSColor.textBackgroundColor.CGColor;
    self.layer.borderColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? .09 : .07].CGColor;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

@implementation LTCard {
    LTCardClip *_clip;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _clip = [[LTCardClip alloc] initWithFrame:self.bounds];
        _clip.wantsLayer = YES;
        _clip.layer.masksToBounds = YES;
        _clip.layer.cornerRadius = 10;
        _clip.layer.cornerCurve = kCACornerCurveContinuous;
        _clip.layer.borderWidth = 1;
        _clip.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_clip];
    }
    return self;
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    BOOL dark = LTAppearanceIsDark(self.effectiveAppearance);
    self.layer.shadowColor = NSColor.blackColor.CGColor;
    self.layer.shadowOpacity = dark ? .35 : .12;
    self.layer.shadowRadius = dark ? 4 : 3;
    self.layer.shadowOffset = CGSizeMake(0, -1);
    SetShadowPath(self.layer, self.bounds, 10);
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    SetShadowPath(self.layer, self.bounds, 10);
}
- (void)host:(NSView *)view {
    NSView *old = _hosted;
    if (old == view && view.superview == _clip)
        return;
    if (old && old != view && old.superview == _clip)
        [old removeFromSuperview];
    _hosted = view;
    if (!view)
        return;
    [_clip addSubview:view];
    view.frame = _clip.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}
@end
