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

/** Websocket to connect to RTM API. */
@property (nonatomic) PSWebSocket *slackSocket;

/** Settings property for team authentication token. */
@property (copy, nonatomic) NSString *existingAuthToken;

/** Settings property for selected channel name. */
@property (copy, nonatomic) NSString *existingChannelName;

/** Holding property for message contents. This patch runs asynchronously,
    so we can't directly set the output property when RTM events come in.
 */
@property (copy) NSString *existingMessageContent;

/** Channels on connected Slack team. */
@property (copy) NSDictionary *channels;

/** Connection for authentication request. */
@property (nonatomic) NSURLConnection *authConnection;

/** Data collected from authentication request response. */
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
 
    self.authRequestData = nil;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.existingMessageContent = connectionFailedMessage;
}


#pragma mark - API related methods

/** Send an authentication request to the rtm.start method,
    hoping to get back a success message that has the RTM websocket url */
- (void)startAuthenticationRequest
{
    NSMutableURLRequest *socketRequest = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://slack.com/api/rtm.start?token=%@", self.existingAuthToken]]];
    
    self.authConnection = [[NSURLConnection alloc] initWithRequest:socketRequest delegate:self];
}

/** Takes a websocket URL string and opens up a websocket connection.
    @param socketURLString An NSString that is the URL for the websocket.
 */
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

/** Take an array of dictionaries representing channels from the authentication
    request response, turn them into PZChannel objects, and save them for later use.
    @param channelArray Array of dictionaries representing channels.
 */
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

/** Extracts the message text from a dictionary representing an RTM api
    message event (if it's the sort of message we want).
    @param messageJSON A dictionary representing a RTM API message event.
 */
- (NSString *)textFromMessage:(NSDictionary *)messageJSON
{
    if ([messageJSON[@"type"] isEqual:@"message"] && (messageJSON[@"subtype"] == nil)) {
        return (NSString *)messageJSON[@"text"];
    }
    
    return nil;
}

/** Take an NSDictionary of messageJSON, extract the text, and store it as
    the latest message for a channel. This is so that if the user switches
    channels, the latest message is already available without another API
    call. If the message is in the currently selected channel, the holding
    property for the outputMessage is set to the message text.
    @param messageJSON A dictionary representing a RTM API message event.
 */
- (void)handleMessageJSON:(NSDictionary *)messageJSON
{
    NSString *textFromMessage = [self textFromMessage:messageJSON];
    if (textFromMessage) {
        PZChannel *messageChannel = self.channels[messageJSON[@"channel"]];
        messageChannel.lastMessageText = textFromMessage;
        if ([messageChannel.name caseInsensitiveCompare:self.existingChannelName] == NSOrderedSame) {
            self.existingMessageContent = textFromMessage;
        }
    }
}

/** Find the latest message for the set channel name, and set the holding
    property to that text.
 */
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


#pragma mark - Settings properties & related methods

- (QCPlugInViewController*) createViewController
{
    return [[QCPlugInViewController alloc]
            initWithPlugIn:self
            viewNibName:@"PiezoSettings"];
}

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
