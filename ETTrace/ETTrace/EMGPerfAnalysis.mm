//
//  Constructor.m
//  PerfAnalysis
//
//  Created by Noah Martin on 11/23/22.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "EMGWriteLibraries.h"
#import <vector>
#import <mutex>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <mach-o/arch.h>
#import <sys/utsname.h>
#import "EMGChannelListener.h"
#import <QuartzCore/QuartzCore.h>
#import "PerfAnalysis.h"
#include <map>

NSString *const kEMGSpanStarted = @"EmergeMetricStarted";
NSString *const kEMGSpanEnded = @"EmergeMetricEnded";

@implementation EMGPerfAnalysis

static thread_t sMainMachThread = {0};
static thread_t sETTraceThread = {0};

static const int kMaxFramesPerStack = 512;
static NSThread *sStackRecordingThread = nil;
typedef struct {
    CFTimeInterval time;
    uint64_t frameCount;
    uintptr_t frames[kMaxFramesPerStack];
} Stack;

typedef struct {
    std::vector<Stack> *stacks;
    char name[256];
} Thread;
static std::map<unsigned int, Thread *> *sThreadsMap;
static std::mutex sThreadsLock;

static dispatch_queue_t fileEventsQueue;

static EMGChannelListener *channelListener;
static NSMutableArray <NSDictionary *> *sSpanTimes;
static BOOL sRecordAllThreads = false;

extern "C" {
void FIRCLSWriteThreadStack(thread_t thread, uintptr_t *frames, uint64_t framesCapacity, uint64_t *framesWritten);
}

+ (Thread *) createThread:(thread_t) threadId
{
    Thread *thread = new Thread;
    
    if(threadId == sMainMachThread) {
        strcpy(thread->name,"Main Thread");
    } else {
        // Get thread Name
        char name[256];
        pthread_t pt = pthread_from_mach_thread_np(threadId);
        if (pt) {
            name[0] = '\0';
            int rc = pthread_getname_np(pt, name, sizeof name);
            strcpy(thread->name, name);
        }
    }
    
    // Create stacks vector
    thread->stacks = new std::vector<Stack>;
    thread->stacks->reserve(400);
    
    return thread;
}

+ (void)recordStackForAllThreads
{
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    if (sRecordAllThreads) {
        if (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) {
            thread_count = 0;
        }
    } else {
        threads = &sMainMachThread;
        thread_count = 1;
    }
    
    // Suspend all threads but ETTrace's
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        if (threads[i] != sETTraceThread) {
            thread_suspend(threads[i]);
        }
    }
    
    CFTimeInterval time = CACurrentMediaTime();
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        if (threads[i] == sETTraceThread) {
            continue;
        }
        
        Stack stack;
        stack.time = time;
        FIRCLSWriteThreadStack(threads[i], stack.frames, kMaxFramesPerStack, &(stack.frameCount));
        
        std::vector<Stack> *threadStack;
        sThreadsLock.lock();
        if (sThreadsMap->find(threads[i]) == sThreadsMap->end()) {
            Thread *thread = [self createThread:threads[i]];
            // Add to hash map
            sThreadsMap->insert(std::pair<unsigned int, Thread *>(threads[i], thread));
            
            threadStack = thread->stacks;
        } else {
            threadStack = sThreadsMap->at(threads[i])->stacks;
        }

        try {
            threadStack->emplace_back(stack);
        } catch (const std::length_error& le) {
            fflush(stdout);
            fflush(stderr);
            throw le;
        }
        sThreadsLock.unlock();
    }
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        if (threads[i] != sETTraceThread)
            thread_resume(threads[i]);
    }
}

+ (void)setupStackRecording:(BOOL) recordAllThreads
{
    if (sStackRecordingThread != nil) {
        return;
    }
    
    sSpanTimes = [NSMutableArray array];

    // Make sure that +recordStack is always called on the same (non-main) thread.
    // This is because a Process keeps its own "current thread" variable which we need
    // to keep separate
    // from the main thread. This is because unwinding itself from the main thread
    // requires Crashlyics to use a hack, and because the stack recording would show up
    // in the trace. The current strategy is to sleep for 4.5 ms because
    // usleep is guaranteed to sleep more than that, in practice ~5ms. We could use a
    // dispatch_timer, which at least tries to compensate for drift etc., but the
    // timer's queue could theoretically end up run on the main thread
    sRecordAllThreads = recordAllThreads;
    
    sThreadsMap = new std::map<unsigned int, Thread *>;
    
    sStackRecordingThread = [[NSThread alloc] initWithBlock:^{
        if (!sETTraceThread) {
            sETTraceThread = mach_thread_self();
        }
        
        NSThread *thread = [NSThread currentThread];
        while (!thread.cancelled) {
            [self recordStackForAllThreads];
            usleep(4500);
        }
    }];
    sStackRecordingThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [sStackRecordingThread start];
}

+ (void)stopRecordingThread {
    [sStackRecordingThread cancel];
    sStackRecordingThread = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [EMGPerfAnalysis stopRecording];
    });
}

+ (void)setupRunAtStartup:(BOOL) recordAllThreads {
    [[NSUserDefaults standardUserDefaults] setBool:true forKey:@"runAtStartup"];
    [[NSUserDefaults standardUserDefaults] setBool:recordAllThreads forKey:@"recordAllThreads"];
    exit(0);
}

+ (void)startObserving {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-perf-analysis"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:emergeDirectoryURL.path isDirectory:NULL]) {
            [[NSFileManager defaultManager] createDirectoryAtURL:emergeDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        channelListener = [[EMGChannelListener alloc] init];
    });
    
    [[NSNotificationCenter defaultCenter] addObserverForName:kEMGSpanStarted
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull notification) {
        if (sStackRecordingThread == nil) {
            return;
        }
        
        NSString *span = notification.userInfo[@"metric"];
        [sSpanTimes addObject:@{
            @"span": span,
            @"type": @"start",
            @"time": @(CACurrentMediaTime())
        }];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:kEMGSpanEnded
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull notification) {
        if (sStackRecordingThread == nil) {
            return;
        }
        
        NSString *span = notification.userInfo[@"metric"];
        [sSpanTimes addObject:@{
            @"span": span,
            @"type": @"stop",
            @"time": @(CACurrentMediaTime())
        }];
    }];
}

+ (BOOL)isRunningOnSimulator
{
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

+ (NSString *)osBuild {
    int mib[2] = {CTL_KERN, KERN_OSVERSION};
    u_int namelen = sizeof(mib) / sizeof(mib[0]);
    size_t bufferSize = 0;

    NSString *osBuildVersion = nil;

    // Get the size for the buffer
    sysctl(mib, namelen, NULL, &bufferSize, NULL, 0);

    u_char buildBuffer[bufferSize];
    int result = sysctl(mib, namelen, buildBuffer, &bufferSize, NULL, 0);

    if (result >= 0) {
        osBuildVersion = [[NSString alloc] initWithBytes:buildBuffer length:bufferSize encoding:NSUTF8StringEncoding];
    }

    NSCharacterSet *nonAlphanumericStrings = [[NSCharacterSet alphanumericCharacterSet] invertedSet];

    // Remove final NULL character
    return [osBuildVersion stringByTrimmingCharactersInSet:nonAlphanumericStrings];
}

+ (NSString *)deviceName {
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

+ (NSArray <NSDictionary <NSString *, id> *> *) arrayFromStacks: (std::vector<Stack>)stacks {
    NSMutableArray <NSDictionary <NSString *, id> *> *threadStacks = [NSMutableArray array];
    for (const auto &cStack : stacks) {
        NSMutableArray <NSNumber *> *stack = [NSMutableArray array];
        // Add the addrs in reverse order so that they start with the lowest frame, e.g. `start`
        for (int j = (int)cStack.frameCount - 1; j >= 0; j--) {
            [stack addObject:@((NSUInteger)cStack.frames[j])];
        }
        NSDictionary *stackDictionary = @{
            @"stack": [stack copy],
            @"time": @(cStack.time)
        };
        [threadStacks addObject:stackDictionary];
    }
    return threadStacks;
}

+ (void)stopRecording {
    sThreadsLock.lock();
    NSMutableDictionary <NSString *, NSDictionary<NSString *, id> *> *threads = [NSMutableDictionary dictionary];

    std::map<unsigned int, Thread *>::iterator it;
    for (it = sThreadsMap->begin(); it != sThreadsMap->end(); it++) {
        Thread thread = *it->second;
        NSString *threadId = [[NSNumber numberWithUnsignedInt:it->first] stringValue];
        threads[threadId] = @{
            @"name": [NSString stringWithFormat:@"%s", thread.name],
            @"stacks": [self arrayFromStacks: *thread.stacks]
        };
    }
    sThreadsMap->empty();
    sThreadsLock.unlock();
        
    const NXArchInfo *archInfo = NXGetLocalArchInfo();
    NSString *cpuType = [NSString stringWithUTF8String:archInfo->description];
    NSMutableDictionary *info = [@{
        @"libraryInfo": EMGLibrariesData(),
        @"isSimulator": @([self isRunningOnSimulator]),
        @"osBuild": [self osBuild],
        @"cpuType": cpuType,
        @"device": [self deviceName],
        @"events": sSpanTimes,
        @"threads": threads,
    } mutableCopy];
    
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:&error];
    if (error) {
        @throw error;
    }
    NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-output"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:emergeDirectoryURL.path isDirectory:NULL]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:emergeDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSURL *outputURL = [emergeDirectoryURL URLByAppendingPathComponent:@"output.json"];
    BOOL result = [data writeToURL:outputURL options:NSDataWritingAtomic error:&error];
    if (!result || error) {
        NSLog(@"Error writing ETTrace state %@", error);
    } else {
        NSLog(@"ETTrace result written");
    }
    [channelListener sendReportCreatedMessage];
}

+ (void)load {
    NSLog(@"Starting ETTrace");
    sMainMachThread = mach_thread_self();
    fileEventsQueue = dispatch_queue_create("com.emerge.file_queue", DISPATCH_QUEUE_SERIAL);
    EMGBeginCollectingLibraries();
    BOOL infoPlistRunAtStartup = ((NSNumber *) NSBundle.mainBundle.infoDictionary[@"ETTraceRunAtStartup"]).boolValue;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"runAtStartup"] || infoPlistRunAtStartup) {
        sRecordAllThreads = [[NSUserDefaults standardUserDefaults] boolForKey:@"recordAllThreads"];
        [EMGPerfAnalysis setupStackRecording:sRecordAllThreads];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"runAtStartup"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"recordAllThreads"];
    }
    [EMGPerfAnalysis startObserving];
}

+ (NSURL *) outputPath {
    NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-output"];
    return [emergeDirectoryURL URLByAppendingPathComponent:@"output.json"];
}

@end
