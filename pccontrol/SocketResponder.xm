#include "SocketServer.h"
#include <string.h>

int notifyClient(UInt8* msg, CFWriteStreamRef client)
{
    int result;
    if (client != 0)
    {
        result = CFWriteStreamWrite(client, msg, strlen((char*)msg));
    }
    result = -1;
    return result;
}
