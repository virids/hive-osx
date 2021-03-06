//
//  HITransaction.m
//  Hive
//
//  Created by Bazyli Zygan on 18.06.2013.
//  Copyright (c) 2013 Hive Developers. All rights reserved.
//

#import "HIContact.h"
#import "HITransaction.h"

NSString * const HITransactionEntity = @"HITransaction";


@implementation HITransaction

@dynamic id;
@dynamic amount;
@dynamic senderName;
@dynamic senderHash;
@dynamic date;
@dynamic senderEmail;
@dynamic confirmations;
@dynamic request;
@dynamic contact;
@dynamic read;

- (HITransactionDirection)direction
{
    return (self.amount >= 0) ? HITransactionDirectionIncoming : HITransactionDirectionOutgoing;
}

- (uint64_t)absoluteAmount
{
    return llabs(self.amount);
}

@end
