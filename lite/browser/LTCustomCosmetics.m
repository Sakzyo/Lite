#import "LTCustomCosmetics.h"
#include <arpa/inet.h>

static BOOL Refuse(NSString **reason, NSString *message) {
    if (reason) *reason = message;
    return NO;
}
static BOOL NameStart(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
static BOOL NameCharacter(unichar c) {
    return NameStart(c) || (c >= '0' && c <= '9') || c == '-';
}
// CSS identifiers without escapes or non-ASCII characters. A leading hyphen must
// be followed by another hyphen or an ordinary identifier start.
static BOOL Identifier(NSString *text, NSUInteger *position) {
    NSUInteger p = *position;
    if (p == text.length) return NO;
    if ([text characterAtIndex:p] == '-') {
        if (++p == text.length) return NO;
        if ([text characterAtIndex:p] != '-' && !NameStart([text characterAtIndex:p])) return NO;
    } else if (!NameStart([text characterAtIndex:p])) return NO;
    ++p;
    while (p < text.length && NameCharacter([text characterAtIndex:p])) ++p;
    *position = p;
    return YES;
}
static BOOL Spaces(NSString *text, NSUInteger *position) {
    NSUInteger before = *position;
    while (*position < text.length && [text characterAtIndex:*position] == ' ') ++*position;
    return *position != before;
}
static BOOL UnsupportedSelector(NSString *text, NSUInteger position, NSString **reason) {
    if (position < text.length) {
        unichar c = [text characterAtIndex:position];
        if (c == ':') return Refuse(reason, @"Pseudo-classes, pseudo-elements and procedural cosmetic filters are not supported.");
        if (c == '\\') return Refuse(reason, @"CSS escapes are not supported.");
        if (c == '{' || c == '}' || c == ';' || c == '@')
            return Refuse(reason, @"Enter CSS selectors only; declarations and CSS rules are not supported.");
        if (c == '|') return Refuse(reason, @"CSS namespaces are not supported.");
    }
    return Refuse(reason, @"Use a type, *, .class, #id or attribute selector, separated by spaces, >, +, ~ or commas.");
}
static BOOL Attribute(NSString *text, NSUInteger *position, NSString **reason) {
    NSUInteger p = *position + 1; // Opening [.
    Spaces(text, &p);
    if (!Identifier(text, &p)) return Refuse(reason, @"An attribute selector needs an ASCII attribute name without escapes.");
    Spaces(text, &p);
    if (p < text.length && [text characterAtIndex:p] == ']') {
        *position = p + 1;
        return YES;
    }
    if (p == text.length) return Refuse(reason, @"Close each attribute selector with ].");
    unichar c = [text characterAtIndex:p++];
    if (c != '=') {
        if ((c != '^' && c != '$' && c != '*' && c != '~' && c != '|') ||
            p == text.length || [text characterAtIndex:p++] != '=')
            return Refuse(reason, @"Attribute selectors support only =, ^=, $=, *=, ~= and |= operators.");
    }
    Spaces(text, &p);
    if (p == text.length) return Refuse(reason, @"An attribute operator needs a value and closing ].");
    c = [text characterAtIndex:p];
    if (c == '\'' || c == '"') {
        unichar quote = c;
        ++p;
        while (p < text.length && [text characterAtIndex:p] != quote) {
            if ([text characterAtIndex:p] == '\\') return Refuse(reason, @"CSS escapes are not supported.");
            ++p;
        }
        if (p == text.length) return Refuse(reason, @"Close each quoted attribute value with its matching quote.");
        ++p;
    } else if (!Identifier(text, &p)) {
        return Refuse(reason, @"Quote attribute values unless they are ASCII CSS identifiers; escapes are not supported.");
    }
    Spaces(text, &p);
    if (p == text.length || [text characterAtIndex:p] != ']')
        return Refuse(reason, @"End the attribute value with ]; attribute flags and extra tokens are not supported.");
    *position = p + 1;
    return YES;
}
static BOOL Compound(NSString *text, NSUInteger *position, NSString **reason) {
    NSUInteger p = *position;
    BOOL found = NO;
    if (p < text.length && [text characterAtIndex:p] == '*') {
        ++p;
        found = YES;
    } else found = Identifier(text, &p);
    while (p < text.length) {
        unichar c = [text characterAtIndex:p];
        if (c == '.' || c == '#') {
            ++p;
            if (!Identifier(text, &p)) return Refuse(reason, @"A class or ID selector needs an ASCII CSS identifier without escapes.");
        } else if (c == '[') {
            if (!Attribute(text, &p, reason)) return NO;
        } else break;
        found = YES;
    }
    if (!found) return UnsupportedSelector(text, p, reason);
    *position = p;
    return YES;
}
static BOOL Selectors(NSString *text, NSMutableArray<NSString *> *selectors, NSString **reason) {
    if (!text.length) return Refuse(reason, @"A cosmetic rule needs a CSS selector.");
    if ([text hasPrefix:@"+js("])
        return Refuse(reason, @"Scriptlets are not supported by custom cosmetic filters.");
    for (NSUInteger i = 0; i < text.length; ++i) {
        unichar c = [text characterAtIndex:i];
        if (c < 32 || c >= 127)
            return Refuse(reason, @"CSS selectors must use printable ASCII characters; control characters and escapes are not supported.");
    }
    NSUInteger p = 0, start = 0;
    if (!Compound(text, &p, reason)) return NO;
    while (p < text.length) {
        BOOL descendant = Spaces(text, &p);
        if (p == text.length) break;
        unichar c = [text characterAtIndex:p];
        if (c == ',' || c == '>' || c == '+' || c == '~') {
            if (c == ',') [selectors addObject:[[text substringWithRange:NSMakeRange(start, p - start)]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
            ++p;
            Spaces(text, &p);
            if (p == text.length) return Refuse(reason, @"A comma or combinator must be followed by another selector.");
            if (c == ',') start = p;
        } else if (!descendant) return UnsupportedSelector(text, p, reason);
        if (!Compound(text, &p, reason)) return NO;
    }
    [selectors addObject:[[text substringFromIndex:start]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    return YES;
}
static BOOL Hostname(NSString *host) {
    if (!host.length || host.length > 253) return NO;
    BOOL numeric = YES;
    for (NSUInteger i = 0; i < host.length; ++i) {
        unichar c = [host characterAtIndex:i];
        if (c != '.' && !(c >= '0' && c <= '9')) numeric = NO;
        if (c != '.' && c != '-' && !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9')) return NO;
    }
    if (numeric) {
        struct in_addr address;
        return inet_pton(AF_INET, host.UTF8String, &address) == 1;
    }
    for (NSString *label in [host componentsSeparatedByString:@"."])
        if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) return NO;
    return YES;
}

NSDictionary<NSString *, id> *LTParseCustomCosmeticFilter(NSString *line, NSString **reason) {
    if (reason) *reason = nil;
    NSRange marker = [line rangeOfString:@"#"];
    if (marker.location == NSNotFound) {
        Refuse(reason, @"A cosmetic rule uses ## to hide or #@# for an exception.");
        return nil;
    }
    NSString *tail = [line substringFromIndex:marker.location];
    BOOL exception = [tail hasPrefix:@"#@#"];
    if (!exception && ![tail hasPrefix:@"##"]) {
        Refuse(reason, @"Only ## hides and #@# exceptions are supported; procedural, scriptlet and replacement filters are not supported.");
        return nil;
    }
    NSString *host = [line substringToIndex:marker.location];
    BOOL asciiHost = YES;
    for (NSUInteger i = 0; i < host.length; ++i) if ([host characterAtIndex:i] >= 127) asciiHost = NO;
    host = host.lowercaseString;
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (marker.location && (!asciiHost || !Hostname(host))) {
        Refuse(reason, @"Use one ASCII hostname before ## or #@#, or leave it empty for a generic rule. Domain lists, exclusions, entities, ports and schemes are not supported.");
        return nil;
    }
    NSString *selector = [[tail substringFromIndex:exception ? 3 : 2]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *selectors = [NSMutableArray new];
    if (!Selectors(selector, selectors, reason)) return nil;
    return @{@"host": host, @"selectors": [selectors copy], @"exception": @(exception)};
}
