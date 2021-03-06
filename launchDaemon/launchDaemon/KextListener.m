//
//  file: KextListener.m
//  project: lulu (launch daemon)
//  description: listener for events from kernel
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

@import Foundation;

#import "Rule.h"
#import "const.h"
#import "Rules.h"
#import "Queue.h"
#import "logging.h"
#import "procInfo.h"
#import "KextComms.h"
#import "Utilities.h"
#import "KextListener.h"
#import "ProcListener.h"
#import "UserClientShared.h"

//global rules obj
extern Rules* rules;

//global kext comms obj
extern KextComms* kextComms;

//global queue object
extern Queue* eventQueue;

//global process monitor
extern ProcessListener* processListener;

//global client status
extern NSInteger clientStatus;

@implementation KextListener

@synthesize alerts;

//init
-(id)init
{
    //init super
    self = [super init];
    if(nil != self)
    {
        //init alerts list
        alerts = [NSMutableSet set];
    }
    
    return self;
}

//kick off threads to monitor for kext events
-(void)monitor
{
    //start thread to get connection notifications from kext
    //[NSThread detachNewThreadSelector:@selector(recvNotifications) toTarget:self withObject:nil];
    
    //start thread to listen for queue events from kext
    [NSThread detachNewThreadSelector:@selector(processEvents) toTarget:self withObject:nil];

    return;
}


/* 

// by design, anybody can subscribe to these events
// the code below illustrates this...
 
//thread function
// recv() broadcast connection notification events from kext
-(void)recvNotifications
{
    //status var
    int status = -1;
    
    //system socket
    int systemSocket = -1;
    
    //struct for vendor code
    // ->set via call to ioctl/SIOCGKEVVENDOR
    struct kev_vendor_code vendorCode = {0};
    
    //struct for kernel request
    // ->set filtering options
    struct kev_request kevRequest = {0};
    
    //struct for broadcast data from the kext
    struct kern_event_msg *kernEventMsg = {0};
    
    //message from kext
    // ->size is cumulation of header, struct, and max length of a proc path
    char kextMsg[KEV_MSG_HEADER_SIZE + sizeof(struct connectionEvent)] = {0};
    
    //bytes received from system socket
    ssize_t bytesReceived = -1;
    
    //custom struct
    // ->process data from kext
    struct connectionEvent* connection = NULL;
    
    //create system socket
    systemSocket = socket(PF_SYSTEM, SOCK_RAW, SYSPROTO_EVENT);
    if(-1 == systemSocket)
    {
        //set status var
        status = errno;
        
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"socket() failed with %d", status]);
        
        //bail
        goto bail;
    }
    
    //set vendor name string
    strncpy(vendorCode.vendor_string, OBJECTIVE_SEE_VENDOR, KEV_VENDOR_CODE_MAX_STR_LEN);
    
    //get vendor name -> vendor code mapping
    status = ioctl(systemSocket, SIOCGKEVVENDOR, &vendorCode);
    if(0 != status)
    {
        //err msg
        //logMsg(LOG_ERR, [NSString stringWithFormat:@"ioctl(...,SIOCGKEVVENDOR,...) failed with %d", status]);
        
        //goto bail;
        goto bail;
    }
    
    //init filtering options
    // ->only interested in objective-see's events
    kevRequest.vendor_code = vendorCode.vendor_code;
    
    //...any class
    kevRequest.kev_class = KEV_ANY_CLASS;
    
    //TODO: maybe just say network events?
    //...any subclass
    kevRequest.kev_subclass = KEV_ANY_SUBCLASS;
    
    //tell kernel what we want to filter on
    status = ioctl(systemSocket, SIOCSKEVFILT, &kevRequest);
    if(0 != status)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"ioctl(...,SIOCSKEVFILT,...) failed with %d", status]);
        
        //goto bail;
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"created system socket & set options, now entering recv() loop");
    #endif
    
    //foreverz
    // ->listen/parse process creation events from kext
    while(YES)
    {
        //ask the kext for process began events
        // ->will block until event is ready
        bytesReceived = recv(systemSocket, kextMsg, sizeof(kextMsg), 0);
        
        //type cast
        // ->to access kev_event_msg header
        kernEventMsg = (struct kern_event_msg*)kextMsg;
        
        //sanity check
        // ->make sure data recv'd looks ok, sizewise
        if( (bytesReceived < KEV_MSG_HEADER_SIZE) ||
            (bytesReceived != kernEventMsg->total_size))
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, [NSString stringWithFormat:@"recv count: %d, wanted: %d", (int)bytesReceived, kernEventMsg->total_size]);
            #endif
            
            //ignore
            continue;
        }
        
        //only care about socket events
        if( (EVENT_CONNECT_OUT != kernEventMsg->event_code) &&
            (EVENT_DATA_OUT != kernEventMsg->event_code) )
        {
            //skip
            continue;
        }
        
        //type cast custom data
        // ->begins right after header
        connection = (struct connectionEvent*)&kernEventMsg->event_data[0];
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"connection event: pid: %d \n", connection->pid]);
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"connection event: local socket: %@ \n", convertSocketAddr(&connection->localAddress)]);
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"connection event: remote socket: %@ \n", convertSocketAddr(&connection->remoteAddress)]);
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"connection event: socket type: %d \n", connection->socketType]);
        
    }//while(YES)
    
//bail
bail:
    
    //close socket
    if(-1 != systemSocket)
    {
        //close
        close(systemSocket);
    }

    return;
}

*/


//process events from the kernel (queue)
// based on code from Singh's 'Mac OS X Internals' pp. 1466
-(void)processEvents
{
    //status
    kern_return_t status = kIOReturnError;
    
    //mach port for receiving queue events
    mach_port_t recvPort = 0;
    
    //mapped memory
    mach_vm_address_t mappedMemory = 0;
    
    //size of mapped memory
    mach_vm_size_t mappedMemorySize = 0;
    
    //data item on queue
    // custom firewall event struct
    firewallEvent event = {0};
    
    //size of data item on queue
    UInt32 eventSize = 0;
    
    //alert info
    NSMutableDictionary* alert = nil;
    
    //process obj
    Process* process = nil;
    
    //matching rule obj
    Rule* matchingRule = nil;
    
    //init size of data item on queue
    eventSize = sizeof(firewallEvent);
    
    //allocate mach port
    // used to receive notifications from IODataQueue
    recvPort = IODataQueueAllocateNotificationPort();
    if(0 == recvPort)
    {
        //err msg
        logMsg(LOG_ERR, @"failed to allocate mach port for queue notifications");
        
        //bail
        goto bail;
    }
    
    //set notification port
    // will call registerNotificationPort() in kext
    status = IOConnectSetNotificationPort(kextComms.connection, 0x1, recvPort, 0x0);
    if(status != kIOReturnSuccess)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to register mach port for queue notifications (error: %d)", status]);
        
        //bail
        goto bail;
    }
    
    //map memory
    // will call clientMemoryForType() in kext
    status = IOConnectMapMemory(kextComms.connection, kIODefaultMemoryType, mach_task_self(), &mappedMemory, &mappedMemorySize, kIOMapAnywhere);
    if(status != kIOReturnSuccess)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to map memory for queue notifications (error: %d)", status]);
        
        //bail
        goto bail;
    }
    
    //wait for data
    while(kIOReturnSuccess == IODataQueueWaitForAvailableData((IODataQueueMemory *)mappedMemory, recvPort))
    {
        //more data?
        while (IODataQueueDataAvailable((IODataQueueMemory *)mappedMemory))
        {
            //reset
            memset(&event, 0x0, sizeof(firewallEvent));
            
            //dequeue a firewall event
            status = IODataQueueDequeue((IODataQueueMemory *)mappedMemory, &event, &eventSize);
            if(kIOReturnSuccess != status)
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to dequeue firewall event (error: %d)", status]);
                
                //next
                continue;
            }
            
            //dbg msg
            logMsg(LOG_DEBUG, [NSString stringWithFormat:@"event from kernel queue: %d /  %@", event.pid, convertSocketAddr((struct sockaddr*)&(event.remoteAddress))]);
            
            //ignore if alert has already been shown for this process
            // if rule is deleted or process ends, this will be reset
            if(YES == [self.alerts containsObject:[NSNumber numberWithUnsignedShort:event.pid]])
            {
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"alert already shown for this process (%d), so ignoring", event.pid]);
                
                //next
                continue;
            }
            
            //nap a bit
            // ->for a processes fork/exec, this should process monitor time to register exec event
            [NSThread sleepForTimeInterval:0.5f];
            
            //try find process via process monitor
            // waits up to one second, since sometime delay in process events
            process = [self findProcess:event.pid];
            if(nil == process)
            {
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"couldn't find process (%d) in process monitor", event.pid]);
                
                //couldn't find proc
                // ->did it die already?
                if(YES != isProcessAlive(event.pid))
                {
                    //dbg msg
                    logMsg(LOG_DEBUG, @"process is dead, so ignoring");
                    
                    //next
                    continue;
                }
                
                //manually create process obj
                process = [[Process alloc] init:event.pid];
            }
            
            //check again
            // ->should have a process obj now
            if(nil == process)
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to find and/or create process object for %d", event.pid]);
                
                //ignore
                // ->not sure what else to do
                continue;
            }
            
            //existing rule for process (path)?
            // TODO: pass in process obj to also validate signature & user
            matchingRule = [rules find:process.path];
            if(nil != matchingRule)
            {
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"found matching rule: %@\n", matchingRule]);
                
                //tell kernel to add rule for this process
                [kextComms addRule:event.pid action:matchingRule.action.unsignedIntValue];
            }
            
            //process doesn't (yet) have a rule
            // if there is an active/enable client, send alert to display/ask user
            else
            {
                //no clients || client disabled
                // default to allow process out...
                if( (STATUS_CLIENT_DISABLED == clientStatus) ||
                    (STATUS_CLIENT_UNKNOWN == clientStatus) )
                {
                    //dbg msg
                    logMsg(LOG_DEBUG, @"no active (enabled) client, so telling kernel to 'allow'");
                    
                    //allow
                    [kextComms addRule:event.pid action:RULE_STATE_ALLOW];
                }
                
                //client is active/enabled
                // queue up alert to trigger delivery to client
                else
                {
                    //create alert
                    alert = [self createAlert:&event process:process];
                              
                    //dbg msg
                    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"no rule found, adding alert to queue: %@", alert]);
                    
                    //add to global queue
                    // ->this will trigger processing of alert
                    [eventQueue enqueue:alert];
                    
                    //note the fact that an alert was shown for this process
                    [self.alerts addObject:[NSNumber numberWithUnsignedShort:event.pid]];
                }
            }
            
        } //IODataQueueDataAvailable
        
    } //IODataQueueWaitForAvailableData
    
bail:
    
    //dbg msg
    // since we shouldn't get here unless error/shutdown
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"returning from %s", __PRETTY_FUNCTION__]);
    
    //unmap memory
    if(0 != mappedMemory)
    {
        //unmap
        status = IOConnectUnmapMemory(kextComms.connection, kIODefaultMemoryType, mach_task_self(), mappedMemory);
        if(kIOReturnSuccess != status)
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to unmap memory (error: %d)", status]);
        }
        
        //unset
        mappedMemory = 0;
    }
    
    //destroy recv port
    if(0 != recvPort)
    {
        //destroy
        mach_port_destroy(mach_task_self(), recvPort);
        
        //unset
        recvPort = 0;
    }
    
    return;
}

//remove process from list of alerts
-(void)resetAlert:(pid_t)pid
{
    //remove
    [self.alerts removeObject:[NSNumber numberWithUnsignedShort:pid]];
    
    return;
}

//try/wait to get process
// ->proc mon sometimes a bit slow...
-(Process*)findProcess:(pid_t)pid
{
    //process obj
    Process* process = nil;

    //count
    NSUInteger i = 0;

    //try up to a second
    for(i=0; i<10; i++)
    {
        //try find process
        process = processListener.processes[[NSNumber numberWithUnsignedShort:pid]];
        if(nil != process)
        {
            //found  it
            break;
        }
        
        //nap
        [NSThread sleepForTimeInterval:0.10f];
    }
    
    return process;
}

//create an alert object
// TODO: need to figure out how to get remote host (sniff DNS response?)
-(NSMutableDictionary*)createAlert:(firewallEvent*)event process:(Process*)process
{
    //event for alert
    NSMutableDictionary* alertInfo = nil;
    
    //remote ip address
    NSString* remoteAddress = nil;
    
    //alloc
    alertInfo = [NSMutableDictionary dictionary];
    
    //covert IP address to string
    remoteAddress = convertSocketAddr((struct sockaddr*)&(event->remoteAddress));
    
    //add pid
    alertInfo[ALERT_PID] = [NSNumber numberWithUnsignedInt:event->pid];
    
    //add path
    alertInfo[ALERT_PATH] = process.path;
    
    //add (remote) ip
    alertInfo[ALERT_IPADDR] = convertSocketAddr((struct sockaddr*)&(event->remoteAddress));
    
    /*
    //add (remote) host name
    if(nil != remoteHost)
    {
        //add
        alertInfo[ALERT_HOSTNAME] = remoteHost;
    }
    */
    
    //add (remote) port
    alertInfo[ALERT_PORT] = [NSNumber numberWithUnsignedShort:ntohs(event->remoteAddress.sin_port)];
    
    //add protocol (socket type)
    alertInfo[ALERT_PROTOCOL] = [NSNumber numberWithInt:event->socketType];
    
    //add signing info
    if(nil != process.binary.signingInfo)
    {
        //add
        alertInfo[ALERT_SIGNINGINFO] = process.binary.signingInfo;
    }
    
    return alertInfo;
}

@end
