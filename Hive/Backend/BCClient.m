//
//  BCClient.m
//  Hive
//
//  Created by Bazyli Zygan on 20.06.2013.
//  Copyright (c) 2013 Hive Developers. All rights reserved.
//

#import <AFNetworking/AFJSONRequestOperation.h>
#import <BitcoinJKit/BitcoinJKit.h>
#import <Tor/Tor.h>
#import "BCClient.h"
#import "HIAppDelegate.h"
#import "HIApplicationsManager.h"
#import "HIContact.h"
#import "HITransaction.h"

static NSString * const kBCClientBaseURLString = @"https://grabhive.com/";

@interface BCClient ()
{
    NSManagedObjectContext *_transactionUpdateContext;
    NSDateFormatter *_dateFormatter;
}

@property (nonatomic) uint64 balance;
@property (nonatomic) uint64 pendingBalance;

@end

@implementation BCClient

+ (BCClient *)sharedClient
{
    static BCClient *sharedClient = nil;
    static dispatch_once_t oncePredicate;

    if (!sharedClient)
    {
        dispatch_once(&oncePredicate, ^{
            sharedClient = [[self alloc] initWithBaseURL:[NSURL URLWithString:kBCClientBaseURLString]];
        });
    }

    return sharedClient;
}

- (id)initWithBaseURL:(NSURL *)URL
{
    self = [super initWithBaseURL:URL];

    if (self)
    {
        [self registerHTTPOperationClass:[AFJSONRequestOperation class]];

        _checkInterval = 10;
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = @"yyyy'-'MM'-'dd'T'HH':'mm':'ssz";

        NSManagedObjectContext *mainContext = [(HIAppDelegate *) [NSApp delegate] managedObjectContext];
        if (!mainContext)
        {
            // something went seriously wrong
            return nil;
        }

        _transactionUpdateContext = [[NSManagedObjectContext alloc]
                                     initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        _transactionUpdateContext.parentContext = mainContext;

        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                               selector:@selector(torStarted:)
                                   name:kHITorManagerStarted
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(bitcoinKitStarted:)
                                   name:kHIBitcoinManagerStartedNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(transactionUpdated:)
                                   name:kHIBitcoinManagerTransactionChangedNotification
                                 object:nil];

        HITorManager *tor = [HITorManager defaultManager];
        tor.dataDirectoryURL = [self torDirectory];
        tor.port = 9999;

        HIBitcoinManager *bitcoin = [HIBitcoinManager defaultManager];
        bitcoin.dataURL = [self bitcoindDirectory];
        bitcoin.exceptionHandler = ^(NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSApp delegate] showExceptionWindowWithException:exception];
            });
        };

#ifdef TESTING_NETWORK
        bitcoin.testingNetwork = YES;
#endif
        
        [bitcoin addObserver:self
                  forKeyPath:@"balance"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];
        [bitcoin addObserver:self
                  forKeyPath:@"estimatedBalance"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];
        [bitcoin addObserver:self
                  forKeyPath:@"syncProgress"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];
        [bitcoin addObserver:self
                  forKeyPath:@"connections"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];

        // TOR disabled for now
        // [tor start];

        [bitcoin start];

        self.balance = [[[NSUserDefaults standardUserDefaults] objectForKey:@"LastBalance"] unsignedLongLongValue];
        self.pendingBalance = 0;

        [self updateNotifications];
    }

    return self;
}

- (void)torStarted:(NSNotification *)notification
{
    [HITorManager defaultManager].torRouting = YES;
}

- (void)bitcoinKitStarted:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self willChangeValueForKey:@"isRunning"];
        [self didChangeValueForKey:@"isRunning"];

        [self willChangeValueForKey:@"walletHash"];
        _walletHash = [HIBitcoinManager defaultManager].walletAddress;
        [self didChangeValueForKey:@"walletHash"];
    });
}

- (void)clearTransactionsList
{
    NSError *error;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:HITransactionEntity];
    NSArray *transactions = [DBM executeFetchRequest:request error:&error];

    if (error)
    {
        NSLog(@"%@: Error loading transactions: %@", NSStringFromSelector(_cmd), error);
        return;
    }

    for (HITransaction *transaction in transactions)
    {
        [DBM deleteObject:transaction];
    }

    [DBM save:&error];

    if (error)
    {
        NSLog(@"%@: Error deleting transactions: %@", NSStringFromSelector(_cmd), error);
        return;
    }
}

- (void)rebuildTransactionsList
{
    NSArray *transactions = [[HIBitcoinManager defaultManager] allTransactions];

    [_transactionUpdateContext performBlock:^{
        for (NSDictionary *transaction in transactions)
        {
            [self parseTransaction:transaction notify:YES];
        }

        NSError *error;
        [_transactionUpdateContext save:&error];

        if (error)
        {
            NSLog(@"Error saving updated transactions: %@", error);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error;
            [DBM save:&error];

            if (error)
            {
                NSLog(@"Error saving updated transactions: %@", error);
            }

            [self updateNotifications];
        });
    }];
}

- (void)transactionUpdated:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *transaction = [[HIBitcoinManager defaultManager] transactionForHash:notification.object];
        [_transactionUpdateContext performBlock:^{
            [self parseTransaction:transaction notify:YES];

            NSError *error;
            [_transactionUpdateContext save:&error];

            if (!error)
            {
                NSLog(@"Saved transaction %@", transaction[@"txid"]);
            }
            else
            {
                NSLog(@"Error saving transaction %@: %@", transaction[@"txid"], error);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error;
                [DBM save:&error];

                if (error)
                {
                    NSLog(@"Error saving transaction %@: %@", transaction[@"txid"], error);
                }

                [self updateNotifications];
            });
        }];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if (object == [HIBitcoinManager defaultManager])
    {
        if ([keyPath isEqual:@"balance"])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.balance = [object balance];
                self.pendingBalance = [object estimatedBalance] - [object balance];

                [[NSUserDefaults standardUserDefaults] setObject:@(self.balance) forKey:@"LastBalance"];
            });
        }
        else if ([keyPath isEqual:@"estimatedBalance"])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.pendingBalance = [object estimatedBalance] - [object balance];
            });
        }
    }
}

- (void)shutdown
{
    [[HIBitcoinManager defaultManager] stop];
    // [[HITorManager defaultManager] stop];
}

- (void)dealloc
{
    [self shutdown];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    @try {
        HIBitcoinManager *manager = [HIBitcoinManager defaultManager];

        [manager removeObserver:self forKeyPath:@"connections"];
        [manager removeObserver:self forKeyPath:@"balance"];
        [manager removeObserver:self forKeyPath:@"estimatedBalance"];
        [manager removeObserver:self forKeyPath:@"syncProgress"];
    }
    @catch (NSException *exception) {
        // there should be a way to check if I'm added as observer before calling remove but I don't know any...
    }
}

- (NSURL *)bitcoindDirectory
{
    NSURL *appSupportURL = [(HIAppDelegate *) [NSApp delegate] applicationFilesDirectory];
    return [appSupportURL URLByAppendingPathComponent:@"BitcoinJ.network"];
}

- (NSURL *)torDirectory
{
    NSURL *appSupportURL = [(HIAppDelegate *) [NSApp delegate] applicationFilesDirectory];
    return [appSupportURL URLByAppendingPathComponent:@"Tor.network"];
}

- (BOOL)isRunning
{
    return [HIBitcoinManager defaultManager].isRunning;
}

- (void)setCheckInterval:(NSUInteger)checkInterval
{
    if (checkInterval == 0)
    {
        return;
    }
    
    _checkInterval = checkInterval;
}


- (NSUInteger)unreadTransactions
{
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:HITransactionEntity];
    req.predicate = [NSPredicate predicateWithFormat:@"read == NO"];
    
    return [_transactionUpdateContext countForFetchRequest:req error:NULL];
}

- (void)updateNotifications
{
    [self willChangeValueForKey:@"unreadTransactions"];
    
    if (self.unreadTransactions > 0)
    {
        [[NSApp dockTile] setBadgeLabel:[NSString stringWithFormat:@"%lu", self.unreadTransactions]];
        [NSApp requestUserAttention:NSInformationalRequest];
    }
    else
    {
        [[NSApp dockTile] setBadgeLabel:@""];
    }

    [self didChangeValueForKey:@"unreadTransactions"];
}

- (NSDictionary *)transactionDefinitionWithHash:(NSString *)hash
{
    return [[HIBitcoinManager defaultManager] transactionForHash:hash];
}

- (BOOL)parseTransaction:(NSDictionary *)data notify:(BOOL)notify
{
    BOOL continueFetching = YES;

    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:HITransactionEntity];
    request.predicate = [NSPredicate predicateWithFormat:@"id == %@", data[@"txid"]];

    NSArray *response = [_transactionUpdateContext executeFetchRequest:request error:NULL];

    if (response.count > 0)
    {
        HITransaction *transaction = response[0];
        
        if (transaction.confirmations != [data[@"confirmations"] integerValue])
        {
            transaction.confirmations = [data[@"confirmations"] integerValue];
        }
        else
        {
            continueFetching = NO;
        }
    }
    else
    {
        HITransaction *transaction = [NSEntityDescription insertNewObjectForEntityForName:HITransactionEntity
                                                                   inManagedObjectContext:_transactionUpdateContext];

        transaction.id = data[@"txid"];
        transaction.date = data[@"time"];
        transaction.amount = [data[@"amount"] longLongValue];
        transaction.request = (![data[@"details"][0][@"category"] isEqual:@"send"]);
        transaction.confirmations = [data[@"confirmations"] integerValue];

        if (!notify)
        {
            transaction.read = YES;
        }

        transaction.senderHash = data[@"details"][0][@"address"];
        
        if (transaction.senderHash)
        {
            // Try to find a contact that matches that transaction
            NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:HIContactEntity];
            request.predicate = [NSPredicate predicateWithFormat:@"ANY addresses.address == %@", transaction.senderHash];

            NSArray *response = [_transactionUpdateContext executeFetchRequest:request error:NULL];

            if (response.count > 0)
            {
                HIContact *contact = response[0];
                transaction.senderName = [NSString stringWithFormat:@"%@ %@", contact.firstname, contact.lastname];
                transaction.senderEmail = contact.email;
                transaction.contact = contact;
            }
        }
    }

    return continueFetching;
}


- (void)sendBitcoins:(uint64)amount
              toHash:(NSString *)hash
          completion:(void(^)(BOOL success, NSString *transactionId))completion
{
    if (amount > self.balance)
    {
        completion(NO, nil);
    }
    else
    {
        HIBitcoinManager *bitcoin = [HIBitcoinManager defaultManager];

        // Sanity check first
        if (amount <= 0 || [bitcoin balance] < amount || ![bitcoin isAddressValid:hash])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil);
            });
        }
        else
        {
            [bitcoin sendCoins:amount
                   toRecipient:hash
                       comment:nil
                    completion:^(NSString *transactionId) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion((transactionId != nil), transactionId);
                });
            }];
        }
    }
}

- (void)sendBitcoins:(uint64)amount
           toContact:(HIContact *)contact
          completion:(void(^)(BOOL success, NSString *transactionId))completion
{
    [self sendBitcoins:amount toHash:contact.account completion:completion];
}

- (BOOL)backupWalletAtURL:(NSURL *)backupURL
{
    return [[HIBitcoinManager defaultManager] exportWalletTo:backupURL];
}

- (BOOL)importWalletFromURL:(NSURL *)walletURL
{
    return [[HIBitcoinManager defaultManager] importWalletFrom:walletURL];
}

@end
