#import "DDDispatchQueueLogFormatter.h"
#import <libkern/OSAtomic.h>

/**
 * Welcome to Cocoa Lumberjack!
 * 
 * The project page has a wealth of documentation if you have any questions.
 * https://github.com/CocoaLumberjack/CocoaLumberjack
 * 
 * If you're new to the project you may wish to read the "Getting Started" wiki.
 * https://github.com/CocoaLumberjack/CocoaLumberjack/wiki/GettingStarted
**/


@implementation DDDispatchQueueLogFormatter
{
    int32_t atomicLoggerCount;
    NSDateFormatter *threadUnsafeDateFormatter; // Use [self stringFromDate]
    
    OSSpinLock lock;
    
    NSUInteger _minQueueLength;           // _prefix == Only access via atomic property
    NSUInteger _maxQueueLength;           // _prefix == Only access via atomic property
    NSMutableDictionary *_replacements;   // _prefix == Only access from within spinlock
}

- (id)init
{
    if ((self = [super init]))
    {
       
        atomicLoggerCount = 0;
        threadUnsafeDateFormatter = nil;
        
        _minQueueLength = 0;
        _maxQueueLength = 0;
        _replacements = [[NSMutableDictionary alloc] init];
        
        // Set default replacements:
        
        _replacements[@"com.apple.main-thread"] = @"main";
    }
    return self;
}


- (void) dealloc
{
   [_replacements release];
   [super dealloc];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize minQueueLength = _minQueueLength;
@synthesize maxQueueLength = _maxQueueLength;

- (NSString *)replacementStringForQueueLabel:(NSString *)longLabel
{
    NSString *result = nil;
    
    OSSpinLockLock(&lock);
    {
        result = _replacements[longLabel];
    }
    OSSpinLockUnlock(&lock);
    
    return result;
}

- (void)setReplacementString:(NSString *)shortLabel forQueueLabel:(NSString *)longLabel
{
    OSSpinLockLock(&lock);
    {
        if (shortLabel)
            _replacements[longLabel] = shortLabel;
        else
            [_replacements removeObjectForKey:longLabel];
    }
    OSSpinLockUnlock(&lock);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark DDLogFormatter
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
static NSDateFormatter NS_RETURNS_RETAINED  *newDDDateFormatter( NSString *formatString)
{
   NSDateFormatter *dateFormatter;
   NSCalendar      *calendar;
   
   dateFormatter = [NSDateFormatter new];
   [dateFormatter setFormatterBehavior:NSDateFormatterBehavior10_4];
   [dateFormatter setDateFormat:formatString];

   // why gregorian ?
   calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
   [dateFormatter setCalendar:calendar];
   [calendar release];
   
   return( dateFormatter);
}

+ (NSString *) dateFormatString
{
   return( @"yyyy-MM-dd HH:mm:ss:SSS");
}


- (NSString *)stringFromDate:(NSDate *)date
{
   NSDateFormatter *dateFormatter;
   
    int32_t loggerCount = OSAtomicAdd32(0, &atomicLoggerCount);
    
    if (loggerCount <= 1)
    {
        // Single-threaded mode.
        
        if (threadUnsafeDateFormatter == nil)
           threadUnsafeDateFormatter = newDDDateFormatter( [[self class] dateFormatString]);
       dateFormatter = threadUnsafeDateFormatter;
    }
    else
    {
        // Multi-threaded mode.
        // NSDateFormatter is NOT thread-safe.
        
        static NSString *key = @"DispatchQueueLogFormatter_NSDateFormatter";
        
        NSMutableDictionary *threadDictionary = [[NSThread currentThread] threadDictionary];

        dateFormatter = threadDictionary[ key];
        if (dateFormatter == nil)
        {
            dateFormatter = newDDDateFormatter( [[self class] dateFormatString]);
            threadDictionary[key] = dateFormatter;
            [dateFormatter autorelease];
        }
    }
   
   return [dateFormatter stringFromDate:date];
}


- (NSString *)queueThreadLabelForLogMessage:(DDLogMessage *)logMessage
{
    // As per the DDLogFormatter contract, this method is always invoked on the same thread/dispatch_queue
    
    NSUInteger minQueueLength = self.minQueueLength;
    NSUInteger maxQueueLength = self.maxQueueLength;
    
    // Get the name of the queue, thread, or machID (whichever we are to use).
    
    NSString *queueThreadLabel = nil;
    
    BOOL useQueueLabel = YES;
    BOOL useThreadName = NO;
    
    if (logMessage->queueLabel)
    {
        // If you manually create a thread, it's dispatch_queue will have one of the thread names below.
        // Since all such threads have the same name, we'd prefer to use the threadName or the machThreadID.
        
        char *names[] = { "com.apple.root.low-priority",
                          "com.apple.root.default-priority",
                          "com.apple.root.high-priority",
                          "com.apple.root.low-overcommit-priority",
                          "com.apple.root.default-overcommit-priority",
                          "com.apple.root.high-overcommit-priority"     };
        
        int length = sizeof(names) / sizeof(char *);
        
        int i;
        for (i = 0; i < length; i++)
        {
            if (strcmp(logMessage->queueLabel, names[i]) == 0)
            {
                useQueueLabel = NO;
                useThreadName = [logMessage->threadName length] > 0;
                break;
            }
        }
    }
    else
    {
        useQueueLabel = NO;
        useThreadName = [logMessage->threadName length] > 0;
    }
    
    if (useQueueLabel || useThreadName)
    {
        NSString *fullLabel;
        NSString *abrvLabel;
        
        if (useQueueLabel)
            fullLabel = @(logMessage->queueLabel);
        else
            fullLabel = logMessage->threadName;
        
        OSSpinLockLock(&lock);
        {
            abrvLabel = _replacements[fullLabel];
        }
        OSSpinLockUnlock(&lock);
        
        if (abrvLabel)
            queueThreadLabel = abrvLabel;
        else
            queueThreadLabel = fullLabel;
    }
    else
    {
        queueThreadLabel = [NSString stringWithFormat:@"%x", logMessage->machThreadID];
    }
    
    // Now use the thread label in the output
    
    NSUInteger labelLength = [queueThreadLabel length];
    
    // labelLength > maxQueueLength : truncate
    // labelLength < minQueueLength : padding
    //                              : exact
    
    if ((maxQueueLength > 0) && (labelLength > maxQueueLength))
    {
        // Truncate
        
        return [queueThreadLabel substringToIndex:maxQueueLength];
    }
    else if (labelLength < minQueueLength)
    {
        // Padding
        
        NSUInteger numSpaces = minQueueLength - labelLength;
        
        char spaces[numSpaces + 1];
        memset(spaces, ' ', numSpaces);
        spaces[numSpaces] = '\0';
        
        return [NSString stringWithFormat:@"%@%s", queueThreadLabel, spaces];
    }
    else
    {
        // Exact
        
        return queueThreadLabel;
    }
}

- (NSString *)formatLogMessage:(DDLogMessage *)logMessage
{
    NSString *timestamp = [self stringFromDate:(logMessage->timestamp)];
    NSString *queueThreadLabel = [self queueThreadLabelForLogMessage:logMessage];
    
    return [NSString stringWithFormat:@"%@ [%@] %@", timestamp, queueThreadLabel, logMessage->logMsg];
}

- (void)didAddToLogger:(id <DDLogger>)logger
{
    OSAtomicIncrement32(&atomicLoggerCount);
}

- (void)willRemoveFromLogger:(id <DDLogger>)logger
{
    OSAtomicDecrement32(&atomicLoggerCount);
}

@end
