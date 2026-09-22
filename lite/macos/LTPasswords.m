#import "LTPasswords.h"
#import "LTUI.h"
NSString *LTLoginReadScript(NSString *origin) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ origin ] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [NSString
        stringWithFormat:
            @"((origin)=>{if(location.origin!==origin[0])return {};const "
            @"p=[...document.querySelectorAll('input[type=password]')].find(e=>e.getClientRects()"
            @".length&&!e.disabled);if(!p)return {};const f=p.form||document;const "
            @"u=f.querySelector('input[autocomplete=username],input[type=email]')||[...f."
            @"querySelectorAll('input')].find(e=>e!==p&&e.getClientRects().length&&['text','"
            @"email'].includes(e.type));return "
            @"{username:(u?.value||'').slice(0,1024),password:p.value.slice(0,16384)}})(%@)",
            json];
}
NSString *LTLoginFillScript(NSDictionary *entry, NSString *password) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"origin" : entry[@"origin"],
        @"username" : entry[@"username"],
        @"password" : password
    }
                                                   options:0
                                                     error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [NSString
        stringWithFormat:@"((c)=>{if(location.origin!==c.origin)return false;const "
                         @"p=[...document.querySelectorAll('input[type=password]')].find(e=>e."
                         @"getClientRects().length&&!e.disabled&&!e.readOnly&&e.autocomplete!=='"
                         @"new-password');if(!p)return false;const f=p.form;if(f&&new "
                         @"URL(f.action||location.href,location.href).origin!==c.origin)return "
                         @"false;const root=f||document;const "
                         @"u=root.querySelector('input[autocomplete=username],input[type=email]'"
                         @")||[...root.querySelectorAll('input')].find(e=>e!==p&&e."
                         @"getClientRects().length&&['text','email'].includes(e.type));const "
                         @"set=(e,v)=>{if(!e||e.disabled||e.readOnly)return;Object."
                         @"getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set."
                         @"call(e,v);e.dispatchEvent(new "
                         @"Event('input',{bubbles:true}));e.dispatchEvent(new "
                         @"Event('change',{bubbles:true}));};set(u,c.username);set(p,c.password)"
                         @";return true;})(%@)",
                         json];
}
static BOOL CanUseLogin(LTPage *page, NSString *origin) {
    return page.alive && origin && [LTLoginOrigin(page.url) isEqual:origin] &&
           (page.secure || [origin hasPrefix:@"http://"]);
}
@implementation LTPasswords {
    LTLoginStore *_store;
}
- (instancetype)initWithStore:(LTLoginStore *)store {
    if ((self = [super init]))
        _store = store;
    return self;
}
- (BOOL)checkPage:(LTPage *)page window:(NSWindow *)window {
    if (!CanUseLogin(page, LTLoginOrigin(page.url))) {
        LTAlert(window, @"A secure website is required",
                @"Open an HTTPS login page before saving or filling a login.");
        return NO;
    }
    return YES;
}
- (void)saveForPage:(LTPage *)page window:(NSWindow *)window {
    if (![self checkPage:page window:window])
        return;
    NSString *origin = LTLoginOrigin(page.url);
    // Read only after the user explicitly chooses Save Login. No page script can access the
    // Keychain.
    [page evaluateJavaScript:LTLoginReadScript(origin)
                  completion:^(id value, BOOL success) {
                    if (!CanUseLogin(page, origin) || !window.visible)
                        return;
                    NSDictionary *fields =
                        success && [value isKindOfClass:NSDictionary.class] ? value : @{};
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = @"Save login in Lite";
                    alert.informativeText = [NSString
                        stringWithFormat:@"%@\nStored securely in your Mac’s Keychain. Saving the "
                                         @"same username updates its password.",
                                         origin];
                    NSTextField *username = [NSTextField new];
                    username.placeholderString = @"Username or email";
                    username.stringValue = [fields[@"username"] isKindOfClass:NSString.class]
                                               ? fields[@"username"]
                                               : @"";
                    NSSecureTextField *password = [NSSecureTextField new];
                    password.placeholderString = @"Password";
                    password.stringValue = [fields[@"password"] isKindOfClass:NSString.class]
                                               ? fields[@"password"]
                                               : @"";
                    NSStackView *form = LTStack(
                        @[
                            LTLabel(@"Username", 12, NSFontWeightMedium), username,
                            LTLabel(@"Password", 12, NSFontWeightMedium), password
                        ],
                        NSUserInterfaceLayoutOrientationVertical, 6);
                    form.frame = NSMakeRect(0, 0, 350, 112);
                    [username.widthAnchor constraintEqualToConstant:350].active = YES;
                    [password.widthAnchor constraintEqualToConstant:350].active = YES;
                    alert.accessoryView = form;
                    [alert addButtonWithTitle:@"Save"];
                    [alert addButtonWithTitle:@"Cancel"];
                    [alert beginSheetModalForWindow:window
                                  completionHandler:^(NSModalResponse result) {
                                    if (result == NSAlertFirstButtonReturn) {
                                        NSError *error;
                                        if (![self->_store saveUsername:username.stringValue
                                                               password:password.stringValue
                                                                 origin:origin
                                                                  error:&error])
                                            LTAlert(window, @"Login was not saved",
                                                    error.localizedDescription);
                                    }
                                    password.stringValue = @"";
                                  }];
                    [alert.window makeFirstResponder:username];
                  }];
}
- (void)fillForPage:(LTPage *)page window:(NSWindow *)window {
    if (![self checkPage:page window:window])
        return;
    NSString *origin = LTLoginOrigin(page.url);
    NSError *error;
    NSMutableArray *entries = [[_store entriesForOrigin:origin error:&error] mutableCopy]
        ?: [NSMutableArray new];
    NSError *keychainError = nil;
    NSArray *keychain = [_store keychainEntriesForOrigin:origin error:&keychainError];
    if (keychain) [entries addObjectsFromArray:keychain];
    if (!error) error = keychainError;
    if (!entries.count) {
        LTAlert(window, error ? @"Could not read saved logins" : @"No saved login for this site",
                error.localizedDescription
                    ?: @"No accessible website password was found in Apple Keychain for this exact site. Apple Passwords/iCloud entries may not be available to Lite. Use Library → Open Apple Passwords, or save a login through Lite.");
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Fill from Apple Keychain";
    alert.informativeText = [NSString
        stringWithFormat:@"%@\nChoose an account. macOS may ask you to unlock its Keychain entry. Lite fills the form without submitting it.%@", origin,
        keychainError ? @" Some Keychain entries could not be accessed." : @""];
    NSPopUpButton *accounts = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 350, 28)];
    for (NSDictionary *entry in entries) {
        NSString *source = entry[@"keychainReference"]
            ? [@"Apple Keychain " stringByAppendingString:entry[@"keychainPath"] ?: @""] : @"Saved by Lite";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ — %@",
            [entry[@"username"] length] ? entry[@"username"] : @"(No username)",
            source] action:nil keyEquivalent:@""];
        item.representedObject = entry;
        [accounts.menu addItem:item];
    }
    alert.accessoryView = accounts;
    [alert addButtonWithTitle:@"Fill"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse result) {
                    if (result != NSAlertFirstButtonReturn || !CanUseLogin(page, origin))
                        return;
                    NSDictionary *entry = accounts.selectedItem.representedObject;
                    if (!entry) return;
                    NSError *error;
                    NSString *password = [self->_store passwordForEntry:entry error:&error];
                    if (!password) {
                        LTAlert(window, @"Could not unlock login", error.localizedDescription);
                        return;
                    }
                    if (!CanUseLogin(page, origin))
                        return;
                    NSString *script = LTLoginFillScript(entry, password);
                    [page evaluateJavaScript:script
                                  completion:^(id value, BOOL success) {
                                    if ((!success || ![value isEqual:@YES]) && window.visible)
                                        LTAlert(
                                            window, @"Login was not filled",
                                            @"Use a visible login form on this website. Cross-site "
                                            @"forms and password-creation forms are not filled.");
                                  }];
                  }];
}
- (void)manageForWindow:(NSWindow *)window {
    NSError *error;
    NSArray *entries = [_store entriesForOrigin:nil error:&error];
    if (!entries.count) {
        LTAlert(window, error ? @"Could not read saved logins" : @"No saved logins",
                error.localizedDescription
                    ?: @"Use Library → Save Login for This Site to add one. Logins stay in this "
                       @"Mac’s Keychain; Google account sync is not available.");
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Saved logins";
    alert.informativeText =
        @"Logins are stored in this Mac’s Keychain. To update a password, save the same username "
        @"again on its website. Google account sync is not available.";
    NSPopUpButton *accounts = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 430, 28)];
    for (NSDictionary *entry in entries)
        [accounts addItemWithTitle:[NSString stringWithFormat:@"%@ — %@", entry[@"origin"],
                                                              entry[@"username"]]];
    alert.accessoryView = accounts;
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Delete Selected…"];
    [alert
        beginSheetModalForWindow:window
               completionHandler:^(NSModalResponse result) {
                 if (result != NSAlertSecondButtonReturn)
                     return;
                 NSDictionary *entry = entries[accounts.indexOfSelectedItem];
                 LTConfirm(
                     window, @"Delete this saved login?",
                     [NSString stringWithFormat:@"%@ — %@", entry[@"origin"], entry[@"username"]],
                     @"Delete", ^{
                       NSError *error;
                       if (![self->_store deleteEntry:entry error:&error])
                           LTAlert(window, @"Could not delete login", error.localizedDescription);
                     });
               }];
}
@end
