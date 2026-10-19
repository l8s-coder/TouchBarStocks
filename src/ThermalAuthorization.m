#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <bsm/libbsm.h>
// Bind code validation to the XPC peer's audit token rather than a reusable PID.
@interface NSXPCConnection (ThermalAudit)
@property(readonly) audit_token_t auditToken;
@end
bool ThermalPeerMatchesHash(NSXPCConnection *connection, NSString *hash) {
    if(![connection respondsToSelector:@selector(auditToken)]) return false;
    if(hash.length!=40 || [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location!=NSNotFound) return false;
    audit_token_t token=connection.auditToken;
    NSDictionary *attributes=@{(__bridge NSString*)kSecGuestAttributeAudit:[NSData dataWithBytes:&token length:sizeof(token)]};
    SecCodeRef guest=NULL; SecRequirementRef requirement=NULL;
    OSStatus status=SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)attributes,kSecCSDefaultFlags,&guest);
    NSString *rule=[NSString stringWithFormat:@"cdhash H\"%@\"",hash];
    if(status==errSecSuccess) status=SecRequirementCreateWithString((__bridge CFStringRef)rule,kSecCSDefaultFlags,&requirement);
    if(status==errSecSuccess) status=SecCodeCheckValidity(guest,kSecCSStrictValidate,requirement);
    if(requirement) CFRelease(requirement); if(guest) CFRelease(guest);
    return status==errSecSuccess;
}
bool ThermalClientAllowed(NSXPCConnection *connection) {
    struct stat console; if(stat("/dev/console",&console)!=0 || console.st_uid==0 || connection.effectiveUserIdentifier!=console.st_uid) return false;
    NSString *hash=[[NSString stringWithContentsOfFile:@"/Library/Application Support/TouchBarStocksThermal/client-hash" encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return ThermalPeerMatchesHash(connection,hash);
}
