//
//  PiezoPlugIn.m
//  Piezo
//
//  Created by Steven Masuch on 2015-12-05.
//  Copyright © 2015 Zanopan. All rights reserved.
//

#import <OpenGL/CGLMacro.h>

#import "PSWebSocket.h"

#import "PiezoPlugIn.h"

#import "PZChannel.h"

#define	kQCPlugIn_Name				@"Piezo"
#define	kQCPlugIn_Description		@"Display the latest message in a Slack channel."

NSString * const executionStartedMessage = @"Execution started";
NSString * const emptyChannelMessage = @"No recent messages in channel";
NSString * const connectionFailedMessage = @"Connection failed";
NSString * const authenticationFailedMessage = @"Authentication failed: %@";
NSString * const authenticationSucceededMessage = @"Authentication succeeded";
NSString * const webSocketFailedMessage = @"Web socket failed";
NSString * const webSocketOpenedMessage = @"Web socket opened";
NSString * const webSocketClosedMessage = @"Web socket closed";


@interface PiezoPlugIn () <PSWebSocketDelegate>

@property (nonatomic) PSWebSocket *slackSocket;

@property (copy, nonatomic) NSString *existingAuthToken;

@property (copy, nonatomic) NSString *existingChannelName;

@property (copy) NSString *existingMessageContent;

@property (copy) NSDictionary *channels;

@property (nonatomic) NSURLConnection *authConnection;

@property (nonatomic) NSMutableData* authRequestData;

@end


@implementation PiezoPlugIn

@dynamic outputMessage;


#pragma mark - Standard patch class methods

+ (NSDictionary *)attributes
{
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary*) attributesForPropertyPortWithKey:(NSString*)key
{
    if([key isEqualToString:@"outputMessage"])
        return [NSDictionary dictionaryWithObjectsAndKeys:
                @"Output message", QCPortAttributeNameKey,
                nil];
    
    return nil;
}

+ (NSArray*)plugInKeys
{
    return [NSArray arrayWithObjects:@"existingAuthToken", @"existingChannelName", nil];
}

+ (QCPlugInExecutionMode)executionMode
{
    return kQCPlugInExecutionModeProvider;
}

+ (QCPlugInTimeMode)timeMode
{
	return kQCPlugInTimeModeTimeBase;
}


#pragma mark - Web socket delegate methods

- (void)webSocketDidOpen:(PSWebSocket *)webSocket {
    self.existingMessageContent = webSocketOpenedMessage;
}

- (void)webSocket:(PSWebSocket *)webSocket didFailWithError:(NSError *)error
{
    self.existingMessageContent = webSocketFailedMessage;
}

- (void)webSocket:(PSWebSocket *)webSocket didReceiveMessage:(id)message
{
    NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *messageJSON = [NSJSONSerialization JSONObjectWithData:messageData options:NSJSONReadingAllowFragments error:nil];
    [self handleMessageJSON:messageJSON];
    
}

- (void)webSocket:(PSWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    self.existingMessageContent = webSocketClosedMessage;
}


#pragma mark - NSURLConnection delegate methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    self.authRequestData = [[NSMutableData alloc] init];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [self.authRequestData appendData:data];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse*)cachedResponse {
    return nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.existingMessageContent = authenticationSucceededMessage;
    NSDictionary *requestResult = [NSJSONSerialization JSONObjectWithData:self.authRequestData options:NSJSONReadingAllowFragments error:nil];
    
    if ([requestResult[@"ok"] boolValue]) {
        [self storeChannels:requestResult[@"channels"]];
        [self startSocket:requestResult[@"url"]];
    } else {
        self.existingMessageContent = [NSString stringWithFormat: authenticationFailedMessage, requestResult[@"error"]];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.existingMessageContent = connectionFailedMessage;
}


#pragma mark - API related methods

- (void)startSocket:(NSString *)socketURLString {
    if (self.slackSocket) {
        [self.slackSocket close];
    }
    
    NSURL *socketURL = [NSURL URLWithString:socketURLString];
    if (socketURL) {
        NSMutableURLRequest *socketRequest = [[NSMutableURLRequest alloc] initWithURL:socketURL];
        
        self.slackSocket = [PSWebSocket clientSocketWithRequest:socketRequest];
        self.slackSocket.delegate = self;
        [self.slackSocket open];
    }
}

- (void)storeChannels:(NSArray *)channelArray
{
    NSMutableDictionary *channelsDictionary = [NSMutableDictionary dictionary];
    for (NSDictionary *channelDictionary in channelArray) {
        PZChannel *channel = [PZChannel new];
        channel.id = channelDictionary[@"id"];
        channel.name = channelDictionary[@"name"];
        channel.lastMessageText = [self textFromMessage:channelsDictionary[@"latest"]] ?: emptyChannelMessage;
        channelsDictionary[channel.id] = channel;
        
        // Set the initial message of the plugin if this is the right channel
        if ([channel.name isEqualToString:self.existingChannelName]) {
            self.existingMessageContent = channel.lastMessageText;
        }
    }
    self.channels = channelsDictionary;
    
}

- (NSString *)textFromMessage:(NSDictionary *)messageJSON
{
    if ([messageJSON[@"type"] isEqual:@"message"] && (messageJSON[@"subtype"] == nil)) {
        return (NSString *)messageJSON[@"text"];
    }
    
    return nil;
}


- (void)handleMessageJSON:(NSDictionary *)messageJSON
{
    NSString *textFromMessage = [self textFromMessage:messageJSON];
    if (textFromMessage) {
        PZChannel *messageChannel = self.channels[messageJSON[@"channel"]];
        messageChannel.lastMessageText = textFromMessage;
        if ([messageChannel.name isEqualToString:self.existingChannelName]) {
            self.existingMessageContent = textFromMessage;
        }
    }
}

- (void)switchChannelSelection
{
    for (PZChannel *channel in [self.channels allValues]) {
        if ([channel.name isEqualToString:self.existingChannelName]) {
            self.existingMessageContent = channel.lastMessageText;
            break;
        }
    }
}


#pragma mark - Plugin execution

- (void)startAuthenticationRequest
{
    NSMutableURLRequest *socketRequest = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://slack.com/api/rtm.start?token=%@", self.existingAuthToken]]];
    
    self.authConnection = [[NSURLConnection alloc] initWithRequest:socketRequest delegate:self];
}

- (void)enableExecution:(id <QCPlugInContext>)context
{
    [self startAuthenticationRequest];
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments
{
    self.outputMessage = self.existingMessageContent;

	return YES;
}

- (void)stopExecution:(id <QCPlugInContext>)context
{
    [self.slackSocket close];
}

- (QCPlugInViewController*) createViewController
{
    return [[QCPlugInViewController alloc]
            initWithPlugIn:self
            viewNibName:@"PiezoSettings"];
}

#pragma mark - Settings properties


- (void)setExistingAuthToken:(NSString *)existingAuthToken
{
    if (![_existingAuthToken isEqualToString:existingAuthToken]) {
        _existingAuthToken = [existingAuthToken copy];
        [self.slackSocket close];
        [self startAuthenticationRequest];
    }
}

- (void)setExistingChannelName:(NSString *)existingChannelName
{
    if (![_existingChannelName isEqualToString:existingChannelName]) {
        _existingChannelName = [existingChannelName copy];
        [self switchChannelSelection];
    }
}

@end
