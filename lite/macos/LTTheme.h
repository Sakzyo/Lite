#import <Cocoa/Cocoa.h>

// Arc-style Space colors. Spaces get a stable automatic palette unless the profile
// stores a named choice in settings[@"spaceThemes"][spaceID].
FOUNDATION_EXPORT NSArray<NSString *> *LTPaletteNames(void);
FOUNDATION_EXPORT NSColor *LTPaletteColor(NSString *name);
FOUNDATION_EXPORT NSString *LTSpacePaletteName(NSDictionary *settings, NSString *spaceID,
                                               BOOL isPrivate);
FOUNDATION_EXPORT NSColor *LTSpaceTint(NSDictionary *settings, NSString *spaceID, BOOL isPrivate);
FOUNDATION_EXPORT NSArray<NSColor *> *LTBackdropColors(NSColor *tint, BOOL dark);
FOUNDATION_EXPORT BOOL LTAppearanceIsDark(NSAppearance *appearance);

// The macOS Accessibility > Display settings that change how Lite draws its own chrome.
// System colors and visual-effect materials follow them on their own; these cover the
// tinted backdrops, washes and borders Lite draws itself.
typedef struct {
    BOOL reduceTransparency;
    BOOL increaseContrast;
} LTDisplayOptions;
FOUNDATION_EXPORT LTDisplayOptions LTCurrentDisplayOptions(void);
// Backdrop gradient stops for explicit options. Reduce Transparency draws one flat color;
// Increase Contrast mutes the tint toward the base so text keeps at least 7:1 contrast.
FOUNDATION_EXPORT NSArray<NSColor *> *LTBackdropColorsWithOptions(NSColor *tint, BOOL dark,
                                                                  LTDisplayOptions options);
// Opacity for a white wash (selection, hover and tile fills) drawn over a backdrop.
FOUNDATION_EXPORT CGFloat LTWashAlpha(CGFloat alpha, BOOL dark, LTDisplayOptions options);
// Hairline border color for floating panels and page cards.
FOUNDATION_EXPORT NSColor *LTBorderColor(BOOL dark, BOOL onBackdrop, LTDisplayOptions options);
// A fill dark enough for white text at 4.5:1 or better; the color itself when it already is.
FOUNDATION_EXPORT NSColor *LTFillForWhiteText(NSColor *fill);
// WCAG 2 contrast ratio between two opaque colors, from 1 to 21.
FOUNDATION_EXPORT CGFloat LTContrastRatio(NSColor *a, NSColor *b);
// Starts redrawing every window when the display settings change. Safe to call repeatedly.
FOUNDATION_EXPORT void LTObserveDisplayOptions(void);

// A lightweight gradient surface backed directly by a CAGradientLayer.
@interface LTBackdrop : NSView
@property (nonatomic, strong) NSColor *tint;
// When NO and not floating, the view is transparent so a parent backdrop shows through.
@property (nonatomic) BOOL drawsBackdrop;
// Rounded, bordered and shadowed panel style used by the floating sidebar.
@property (nonatomic) BOOL floating;
- (void)setTint:(NSColor *)tint animated:(BOOL)animated;
@end

// Rounded, softly shadowed card that hosts web content inside the window chrome.
@interface LTCard : NSView
@property (nonatomic, readonly, weak) NSView *hosted;
// Square, borderless and shadowless style used when the window fills the screen.
@property (nonatomic) BOOL flush;
- (void)host:(NSView *)view;
@end
