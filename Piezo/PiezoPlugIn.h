//
//  PiezoPlugIn.h
//  Piezo
//
//  Created by Steven Masuch on 2015-12-05.
//  Copyright © 2015 Zanopan. All rights reserved.
//

#import <Quartz/Quartz.h>

@interface PiezoPlugIn : QCPlugIn

/** The string containing either the latest message withouth a subtype
    or an status message about connection setup progress or connection error. */
@property (copy) NSString* outputMessage;

@end
