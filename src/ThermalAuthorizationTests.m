#import <Foundation/Foundation.h>
#import <Security/Security.h>
extern bool ThermalPeerMatchesHash(NSXPCConnection *,NSString *);
@protocol Probe
- (void)check:(void(^)(BOOL))reply;
@end
@interface ProbeDelegate : NSObject <NSXPCListenerDelegate,Probe>
@property NSString *hashValue;
@end
@implementation ProbeDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    BOOL allowed=ThermalPeerMatchesHash(c,self.hashValue);
    BOOL rejected=!ThermalPeerMatchesHash(c,@"0000000000000000000000000000000000000000") && !ThermalPeerMatchesHash(c,@"invalid");
    if(!allowed||!rejected) { fprintf(stderr,"FAIL XPC audit-token code identity validation\n"); exit(1); }
    c.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(Probe)]; c.exportedObject=self; [c resume]; return YES;
}
- (void)check:(void(^)(BOOL))reply { reply(YES); }
@end
int main(void) { @autoreleasepool {
    SecCodeRef selfCode=NULL; CFDictionaryRef info=NULL;
    if(SecCodeCopySelf(kSecCSDefaultFlags,&selfCode)!=errSecSuccess || SecCodeCopySigningInformation(selfCode,kSecCSSigningInformation,&info)!=errSecSuccess) return 2;
    NSData *hash=((__bridge NSDictionary*)info)[(__bridge NSString*)kSecCodeInfoUnique];
    NSMutableString *hex=[NSMutableString string]; const unsigned char *bytes=hash.bytes;
    for(NSUInteger i=0;i<hash.length;i++) [hex appendFormat:@"%02x",bytes[i]];
    ProbeDelegate *delegate=[ProbeDelegate new]; delegate.hashValue=hex;
    NSXPCListener *listener=[NSXPCListener anonymousListener]; listener.delegate=delegate; [listener resume];
    NSXPCConnection *c=[[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint]; c.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(Probe)]; [c resume];
    [(id<Probe>)[c remoteObjectProxyWithErrorHandler:^(NSError *e){fprintf(stderr,"FAIL XPC connection\n");exit(3);}] check:^(BOOL success){ puts("PASS XPC audit-token identity accepts pinned signature and rejects wrong or malformed hashes");exit(success?0:4);}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{fprintf(stderr,"FAIL XPC timeout\n");exit(5);});
    CFRelease(info); CFRelease(selfCode); [[NSRunLoop mainRunLoop] run]; return 6;
} }
