#import "ThermalBridge.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOMessage.h>
enum { ThermalWillSleep = kIOMessageSystemWillSleep, ThermalCanSleep = kIOMessageCanSystemSleep };
bool ThermalClientAllowed(NSXPCConnection *connection);
