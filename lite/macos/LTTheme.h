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
- (void)host:(NSView *)view;
@end
