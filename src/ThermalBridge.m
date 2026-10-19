#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <math.h>
#import "ThermalBridge.h"
typedef struct { uint8_t major,minor,build,reserved; uint16_t release; } Version;
typedef struct { uint16_t version,length; uint32_t cpu,gpu,mem; } PLimit;
typedef struct { uint32_t size,type; uint8_t attrs; } KeyInfo;
typedef struct { uint32_t key; Version version; PLimit limit; KeyInfo info; uint8_t result,status,command; uint32_t data; uint8_t bytes[32]; } Message;
_Static_assert(sizeof(Message)==80,"SMC protocol layout");
static char lastError[256]="";
const char *ThermalLastError(void) { return lastError; }
static uint32_t code(const char *s) { return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3]; }
static io_connect_t openSMC(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    io_connect_t c=0; if(service) { IOServiceOpen(service,mach_task_self(),0,&c); IOObjectRelease(service); } return c;
}
static bool call(io_connect_t c, Message *in, Message *out) {
    size_t size=sizeof(*out); memset(out,0,size);
    kern_return_t result=IOConnectCallStructMethod(c,2,in,sizeof(*in),out,&size);
    bool ok=result==KERN_SUCCESS && size==sizeof(*out) && out->result==0;
    if(!ok) snprintf(lastError,sizeof(lastError),"SMC command=%u key=%08x transport=%08x result=%u size=%zu",in->command,in->key,result,out->result,size);
    return ok;
}
static bool readKey(io_connect_t c,const char *key,double *value,KeyInfo *metadata) {
    Message in={0},out={0}; in.key=code(key); in.command=9;
    if(!call(c,&in,&out)||!out.info.size||out.info.size>32) return false;
    KeyInfo info=out.info; in.info.size=info.size; in.command=5;
    if(!call(c,&in,&out)) return false;
    if(info.type==code("flt ")&&info.size==4) { float f; memcpy(&f,out.bytes,4); *value=f; }
    else if(info.type==code("fpe2")&&info.size==2) *value=((out.bytes[0]<<8)|out.bytes[1])/4.0;
    else if(info.type==code("ui8 ")&&info.size==1) *value=out.bytes[0];
    else return false;
    if(metadata) *metadata=info; return isfinite(*value);
}
// Only fan zero is supported. No API accepts arbitrary SMC keys or byte payloads.
static const char *modeKey(io_connect_t c,double *mode) {
    if(readKey(c,"F0Md",mode,NULL)) return "F0Md";
    if(readKey(c,"F0md",mode,NULL)) return "F0md"; return NULL;
}
static bool writeKey(io_connect_t c,const char *key,double value) {
    if(geteuid()!=0 || (strcmp(key,"F0Md") && strcmp(key,"F0md") && strcmp(key,"F0Tg"))) return false;
    double old; KeyInfo info; if(!readKey(c,key,&old,&info)) return false;
    Message in={0},out={0}; in.key=code(key); in.command=6; in.info.size=info.size;
    if(info.type==code("flt ")&&info.size==4) { float f=value; memcpy(in.bytes,&f,4); }
    else if(info.type==code("fpe2")&&info.size==2) { unsigned v=(unsigned)round(value*4); in.bytes[0]=v>>8; in.bytes[1]=v; }
    else if(info.type==code("ui8 ")&&info.size==1) in.bytes[0]=(uint8_t)value;
    else return false;
    return call(c,&in,&out);
}
static double cpuTemperature(void) {
    static void *kit; static dispatch_once_t once;
    dispatch_once(&once,^{ kit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY); });
    if(!kit) return NAN;
    CFTypeRef (*create)(CFAllocatorRef)=dlsym(kit,"IOHIDEventSystemClientCreate");
    void (*match)(CFTypeRef,CFDictionaryRef)=dlsym(kit,"IOHIDEventSystemClientSetMatching");
    CFArrayRef (*services)(CFTypeRef)=dlsym(kit,"IOHIDEventSystemClientCopyServices");
    CFTypeRef (*property)(CFTypeRef,CFStringRef)=dlsym(kit,"IOHIDServiceClientCopyProperty");
    CFTypeRef (*event)(CFTypeRef,int,int64_t,int)=dlsym(kit,"IOHIDServiceClientCopyEvent");
    double (*value)(CFTypeRef,int)=dlsym(kit,"IOHIDEventGetFloatValue");
    if(!create||!match||!services||!property||!event||!value) return NAN;
    CFTypeRef client=create(kCFAllocatorDefault); if(!client) return NAN;
    match(client,(__bridge CFDictionaryRef)@{@"PrimaryUsagePage":@(0xff00),@"PrimaryUsage":@5});
    CFArrayRef list=services(client); double maximum=NAN;
    if(list) for(CFIndex i=0;i<CFArrayGetCount(list);i++) {
        CFTypeRef service=CFArrayGetValueAtIndex(list,i),name=property(service,CFSTR("Product"));
        NSString *label=(__bridge NSString *)name;
        if([label isKindOfClass:NSString.class] && ([label hasPrefix:@"pACC MTR Temp Sensor"]||[label hasPrefix:@"eACC MTR Temp Sensor"])) {
            CFTypeRef sample=event(service,15,0,0);
            if(sample) { double t=value(sample,15<<16); if(isfinite(t)&&t>=10&&t<=125) maximum=isnan(maximum)?t:fmax(maximum,t); CFRelease(sample); }
        }
        if(name) CFRelease(name);
    }
    if(list) CFRelease(list); CFRelease(client); return maximum;
}
bool ThermalRead(ThermalReading *r) {
    memset(r,0,sizeof(*r)); r->temperature=cpuTemperature();
    io_connect_t c=openSMC(); if(!c) return false; double count=0,mode=0;
    bool ok=readKey(c,"FNum",&count,NULL) && count==1 && modeKey(c,&mode) &&
      readKey(c,"F0Ac",&r->actual,NULL) && readKey(c,"F0Mn",&r->minimum,NULL) &&
      readKey(c,"F0Mx",&r->maximum,NULL) && readKey(c,"F0Tg",&r->target,NULL);
    r->fanCount=(int)count; r->mode=(int)mode; IOServiceClose(c);
    return ok && r->minimum>=500 && r->maximum>r->minimum && r->maximum<=15000;
}
bool ThermalRestoreAuto(void) {
    io_connect_t c=openSMC(); if(!c) return false; double mode=0;
    const char *key=modeKey(c,&mode); bool ok=key && (mode==0 || writeKey(c,key,0));
    double verified=-1; ok=ok && modeKey(c,&verified) && verified==0;
    IOServiceClose(c); return ok;
}
bool ThermalSetTarget(double rpm) {
    lastError[0]=0;
    ThermalReading r; if(!ThermalRead(&r)||!isfinite(r.temperature)||!isfinite(rpm)||rpm<r.minimum||rpm>r.maximum) return false;
    io_connect_t c=openSMC(); if(!c) return false; double mode=0; const char *key=modeKey(c,&mode);
    bool ok=key && writeKey(c,key,1) && writeKey(c,"F0Tg",rpm);
    // Mode/target readback can lag the successful write. The control engine
    // verifies both on subsequent samples, retaining ownership until confirmed.
    if(!ok && key) writeKey(c,key,0);
    IOServiceClose(c); return ok;
}
