//
//  EventBus.m
//  EventBus
//
//  Created by 张小刚 on 16/2/29.
//  Copyright © 2016年 DuoHuo Network Technology. All rights reserved.
//

#import "EventBus.h"
#import <objc/runtime.h>

static NSString * const kDEFAULT_BUS_NAME = @"EventBus_defaultBus";

static char * const kNSObjectOfflineKey = "EventBus_OffLine";
static char * const kNSObjectOfflineIntervalKey = "EventBus_OfflineInterval";

static NSString * const kEventSubscribeRecordTime       = @"time";
static NSString * const kEventSubscribeRecordSubscriber = @"subscriber";


@interface NSDate (EventBus)

+ (NSTimeInterval)currentTimeInterval;

@end

@implementation NSDate (EventBus)

+ (NSTimeInterval)currentTimeInterval
{
    return [[NSDate date] timeIntervalSince1970];
}

@end

@interface Event ()

@property (nonatomic, strong) NSPointerArray * readerList;

@end

@implementation Event

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.readerList = [NSPointerArray weakObjectsPointerArray];
    }
    return self;
}

@end

@interface NSObject (EventBusPrivate)

@property (nonatomic, assign) NSTimeInterval offLineInterval;
@property (nonatomic, assign) BOOL offLine;

@end

@interface EventSubscribeRecord : NSObject

@property (nonatomic, assign) NSTimeInterval subscribeTime;
@property (nonatomic, weak) id<EventSubscriber> subscriber;

@end

@implementation EventSubscribeRecord

@end

@interface EventBus ()

@property (nonatomic, strong) NSMutableArray<Event *> * eventList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<EventSubscribeRecord *> *> * subscribeRecords;

@end

@implementation EventBus

+ (EventBus *)defaultBus
{
    return [EventBus busWithName:kDEFAULT_BUS_NAME];
}

+ (EventBus *)busWithName:(NSString *)busName
{
    static NSMutableArray * busList = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        busList = [NSMutableArray array];
    });
    EventBus * targetBus = nil;
    for (EventBus * bus in busList) {
        if ([bus.busName isEqualToString:busName]) {
            targetBus = bus;
            break;
        }
    }
    if (!targetBus) {
        EventBus * eventBus = [[EventBus alloc] init];
        eventBus.busName = busName;
        [busList addObject:eventBus];
        targetBus = eventBus;
    }
    return targetBus;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.eventList = [NSMutableArray array];
        self.subscribeRecords = [NSMutableDictionary dictionary];
    }
    return self;
}

//订阅
- (void)subscribeEvent:(NSString *)eventName subscriber:(id<EventSubscriber>)subscriber
{
    EventSubscribeRecord * targetSubscribeRecord = nil;
    NSMutableArray<EventSubscribeRecord *> * subscribeRecords = self.subscribeRecords[eventName];
    if (!subscribeRecords) {
        subscribeRecords = [NSMutableArray array];
    }
    for (EventSubscribeRecord * subscribeRecord in subscribeRecords) {
        if (subscribeRecord.subscriber == subscriber) {
            targetSubscribeRecord = subscribeRecord;
            break;
        }
    }
    if (targetSubscribeRecord) {
        [subscribeRecords removeObject:targetSubscribeRecord];
    }
    id __weak wsubscriber = subscriber;
    EventSubscribeRecord * subscribeRecord = [[EventSubscribeRecord alloc] init];
    subscribeRecord.subscriber = wsubscriber;
    subscribeRecord.subscribeTime = [NSDate currentTimeInterval];
    [subscribeRecords addObject:subscribeRecord];
    self.subscribeRecords[eventName] = subscribeRecords;
    
}

//取消订阅
- (void)unsubscribeEvent:(NSString *)eventName subscriber:(id<EventSubscriber>)subscriber
{
    EventSubscribeRecord * targetSubscribeRecord = nil;
    NSMutableArray * subscribeRecords = self.subscribeRecords[eventName];
    if (!subscribeRecords) {
        subscribeRecords = [NSMutableArray array];
    }
    for (EventSubscribeRecord * subscribeRecord in subscribeRecords) {
        if (subscribeRecord.subscriber == subscriber) {
            targetSubscribeRecord = subscribeRecord;
            break;
        }
    }
    if (targetSubscribeRecord) {
        [subscribeRecords removeObject:targetSubscribeRecord];
    }
    self.subscribeRecords[eventName] = subscribeRecords;
}

//发布
- (void)publishEvent:(NSString *)eventName publisher:(id<EventPublisher>)publisher
{
    [self publishEvent:eventName publisher:publisher params:nil];
}

- (void)publishEvent:(NSString *)eventName publisher:(id<EventPublisher>)publisher params:(id)params
{
    Event * event = [[Event alloc] init];
    event.name = eventName;
    event.publisher = publisher;
    event.publishTime = [NSDate currentTimeInterval];
    event.life = 0;
    if (params) {
        event.params = params;
    }
    NSArray * subscribeRecords = self.subscribeRecords[eventName];
    //顺序从最早注册开始
    for (int i=0;i<subscribeRecords.count;i++) {
        EventSubscribeRecord * subscribeRecord = subscribeRecords[i];
        id<EventSubscriber> eventSubscriber = subscribeRecord.subscriber;
        BOOL offLine = ((NSObject *)eventSubscriber).offLine;
        if(offLine){
            event.life += 1;
        }else{
            if ([eventSubscriber respondsToSelector:@selector(eventOccurred:event:)]) {
                [eventSubscriber eventOccurred:eventName event:event];
                [event.readerList addPointer:(__bridge void * _Nullable)(eventSubscriber)];
            }
        }
    }
    if(event.life > 0){
        [self.eventList addObject:event];
    }
}

//获取从离线以来未读Event
- (NSArray<Event *> *)checkEvent: (NSString *)eventName forSubscriber:(id<EventSubscriber>)subscriber
{
    if(![(NSObject *)subscriber offLine]) return nil;
    NSMutableArray<Event *> * unreadEvents = [NSMutableArray array];
    NSMutableArray<Event *> * toRemovedEvents = [NSMutableArray array];
    NSInteger eventCount = self.eventList.count;
    //倒序检查，从最新的开始
    for (NSInteger i=eventCount-1;i>=0;i--) {
        Event * event = self.eventList[i];
        if ([event.name isEqualToString:eventName]) {
            NSArray * subscribeRecords = self.subscribeRecords[eventName];
            EventSubscribeRecord * subscribeRecord = nil;
            for (EventSubscribeRecord * record in subscribeRecords) {
                if (record.subscriber == subscriber) {
                    subscribeRecord = record;
                    break;
                }
            }
            if(!subscribeRecord) continue;
            BOOL isEventReaded = NO;
            for (id<EventSubscriber> eventReader in event.readerList) {
                if (eventReader == subscriber) {
                    isEventReaded = YES;
                    break;
                }
            }
            if(isEventReaded) continue;
            event.life -= 1;
            [unreadEvents addObject:event];
            [event.readerList addPointer:(__bridge void * _Nullable)(subscriber)];
            if (event.life == 0) {
                [toRemovedEvents addObject:event];
            }
        }
    }
    [self.eventList removeObjectsInArray:toRemovedEvents];
    return unreadEvents;
}

- (BOOL)checkAnyEventsExists: (NSArray *)eventNames forSubscriber: (id<EventSubscriber>)subscriber
{
    BOOL result = NO;
    //read all events firstly
    NSMutableArray<Event *> * allEvents = [NSMutableArray array];
    for (NSString * eventName in eventNames) {
        NSArray<Event *> * events = [self checkEvent:eventName forSubscriber:subscriber];
        if(events.count > 0){
            [allEvents addObjectsFromArray:events];
        }
    }
    if(allEvents.count > 0){
        result = YES;
    }
    return result;
}

- (BOOL)checkAllEventsExist: (NSArray *)eventNames forSubscriber: (id<EventSubscriber>)subscriber
{
    BOOL result = NO;
    //read all events firstly
    NSMutableArray<Event *> * allEvents = [NSMutableArray array];
    for (NSString * eventName in eventNames) {
        NSArray<Event *> * events = [self checkEvent:eventName forSubscriber:subscriber];
        if(events.count > 0){
            [allEvents addObjectsFromArray:events];
        }
    }
    BOOL allExists = YES;
    for (NSString * eventName in eventNames) {
        BOOL isEventExists = NO;
        for (Event * event in allEvents) {
            if([eventName isEqualToString:event.name]){
                isEventExists = YES;
                break;
            }
        }
        if(!isEventExists){
            allExists = NO;
            break;
        }
    }
    result = allExists;
    return result;
}

@end

@implementation NSObject (EventBus)

- (BOOL)eventbus_offLine
{
    return [objc_getAssociatedObject(self, kNSObjectOfflineKey) boolValue];
}

- (void)setEventbus_offLine:(BOOL)offLine
{
    objc_setAssociatedObject(self, kNSObjectOfflineKey,[NSNumber numberWithBool:offLine], OBJC_ASSOCIATION_RETAIN);
    if(offLine){
        self.offLineInterval = [NSDate currentTimeInterval];
    }
}

@end

@implementation NSObject (EventBusPrivate)

- (BOOL)offLine
{
    return [self eventbus_offLine];
}

- (void)setOffLine:(BOOL)offLine
{
    self.eventbus_offLine = offLine;
}

- (NSTimeInterval)offLineInterval
{
    return [objc_getAssociatedObject(self, kNSObjectOfflineIntervalKey) doubleValue];
}

- (void)setOffLineInterval:(NSTimeInterval)offLineInterval
{
    objc_setAssociatedObject(self, kNSObjectOfflineIntervalKey, [NSNumber numberWithDouble:offLineInterval], OBJC_ASSOCIATION_RETAIN);
}



@end









