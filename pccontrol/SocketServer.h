#ifndef SERVER_H
#define SERVER_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

int notifyClient(UInt8* msg, CFWriteStreamRef client);

#endif
