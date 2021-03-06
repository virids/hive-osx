//
//  HIDebuggingInfoWindowController.m
//  Hive
//
//  Created by Jakub Suder on 29.10.2013.
//  Copyright (c) 2013 Hive Developers. All rights reserved.
//

#import <BitcoinJKit/BitcoinJKit.h>
#import "HIDebuggingInfoWindowController.h"
#import "HITransaction.h"

@implementation HIDebuggingInfoWindowController

- (id)init
{
    return [self initWithWindowNibName:@"HIDebuggingInfoWindowController"];
}

- (void)showWindow:(id)sender
{
    [super showWindow:sender];
    [self updateInfo];
}

- (void)updateInfo
{
    NSMutableString *info = [[NSMutableString alloc] init];
    HIBitcoinManager *bitcoin = [HIBitcoinManager defaultManager];

    [info appendFormat:@"## Basic info\n\n"];
    [info appendFormat:@"Data generated at: %@\n", [NSDate date]];
    [info appendFormat:@"Wallet address: %@\n", bitcoin.walletAddress];
    [info appendFormat:@"Wallet balance: %lld\n", bitcoin.balance];
    [info appendFormat:@"Estimated balance: %lld\n", bitcoin.estimatedBalance];

    NSFetchRequest *transactionRequest = [NSFetchRequest fetchRequestWithEntityName:HITransactionEntity];
    transactionRequest.returnsObjectsAsFaults = NO;
    NSArray *transactions = [DBM executeFetchRequest:transactionRequest error:NULL];

    [info appendFormat:@"\n## Data store transactions\n\n"];
    [info appendFormat:@"%@\n", transactions];

    [info appendFormat:@"\n## Wallet transactions\n\n"];
    [info appendFormat:@"%@\n", bitcoin.allTransactions];

    [info appendFormat:@"\n## Wallet details\n\n"];
    [info appendString:bitcoin.walletDebuggingInfo];

    self.textView.string = info;
}

@end
