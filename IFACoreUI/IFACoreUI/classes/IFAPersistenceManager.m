//
//  IFAPersistenceManager.m
//  IFACoreUI
//
//  Created by Marcelo Schroeder on 11/06/10.
//  Copyright 2010 InfoAccent Pty Limited. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "IFACoreUI.h"

static NSString *METADATA_KEY_SYSTEM_DB_TABLES_LOADED = @"systemDbTablesLoaded";
static NSString *METADATA_VALUE_SYSTEM_DB_TABLES_LOADED = @"Y";
static NSString *METADATA_KEY_SYSTEM_DB_TABLES_VERSION = @"systemDbTablesVersion";

@interface IFAPersistenceManager ()

@property (strong) NSManagedObjectModel *managedObjectModel;
@property (strong) NSManagedObjectContext *managedObjectContext;
@property (strong) NSManagedObjectContext *privateQueueChildManagedObjectContext;
//@property BOOL p_isPrivateQueueManagedObjectContextStale;
@property (strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (strong) NSMutableDictionary *IFA_managedObjectChangedValuesDictionary;
@property (strong) NSMutableDictionary *IFA_managedObjectCommittedValuesDictionary;
@property (strong) IFAEntityConfig *entityConfig;
@property (strong) NSDictionary *IFA_metadata;
@property (strong) NSMutableArray *IFA_childManagedObjectContexts;
@property (strong) NSString *threadDictionaryKeyManagedObjectContext;

@property(nonatomic) BOOL IFA_observingManagedObjectContext;
@end

@implementation IFAPersistenceManager

#pragma mark - Overrides

- (id)init{
    self = [super init];
    if (self) {
        self.savesInMainThreadOnly = YES;
        self.IFA_childManagedObjectContexts = [NSMutableArray new];
        self.threadDictionaryKeyManagedObjectContext = [NSString stringWithFormat:@"com.infoaccent.IFACoreUI.PersistenceManager.ManagedObjectContext.%@",
                                                                                  [IFAUtils generateUuid]];
    }
    return self;
}

#pragma mark - Private

-(void (^)(void))IFA_wrapperForBlock:(void (^)(void))a_block managedObjectContext:(NSManagedObjectContext*)a_managedObjectContext{
    return ^{
        NSMutableDictionary *l_threadDict = [[NSThread currentThread] threadDictionary];
        l_threadDict[self.threadDictionaryKeyManagedObjectContext] = a_managedObjectContext;
        a_block();
        [l_threadDict removeObjectForKey:self.threadDictionaryKeyManagedObjectContext];
    };
}

-(NSMutableDictionary*)userInfoForEntityName:(NSString*)a_entityName entityUserInfo:(NSMutableDictionary*)a_entityUserInfoDict{
    if (![a_entityUserInfoDict valueForKey:a_entityName]) {
        NSMutableDictionary *l_userInfoDict = [[NSMutableDictionary alloc] init];
        [l_userInfoDict setValue:[[NSMutableSet alloc] init] forKey:IFAKeyInsertedObjects];
        [l_userInfoDict setValue:[[NSMutableSet alloc] init] forKey:IFAKeyUpdatedObjects];
        [l_userInfoDict setValue:[[NSMutableSet alloc] init] forKey:IFAKeyDeletedObjects];
        [l_userInfoDict setValue:[[NSMutableDictionary alloc] init] forKey:IFAKeyUpdatedProperties];
        [l_userInfoDict setValue:[[NSMutableDictionary alloc] init] forKey:IFAKeyOriginalProperties];
        [a_entityUserInfoDict setValue:l_userInfoDict forKey:a_entityName];
        //        NSLog(@"big dict: %@", [a_entityUserInfoDict description]);
    }
    return [a_entityUserInfoDict valueForKey:a_entityName];
}

- (void)onNotification:(NSNotification*)aNotification{
    
//    NSLog(@" ");
//    NSLog(@"### onNotification: %@", [aNotification name]);

    NSManagedObjectContext *savedManagedObjectContext = aNotification.object;
    if (savedManagedObjectContext != self.managedObjectContext) {
        // If saved MOC is not the same as the main MOC, then ignore notification
        return;
    }

    if ([[aNotification name] isEqual:NSManagedObjectContextWillSaveNotification]) {
        self.IFA_managedObjectChangedValuesDictionary = [[NSMutableDictionary alloc] init];
        self.IFA_managedObjectCommittedValuesDictionary = [[NSMutableDictionary alloc] init];
        for (NSManagedObject *l_managedObject in [self.managedObjectContext updatedObjects]) {
            self.IFA_managedObjectChangedValuesDictionary[l_managedObject.ifa_stringId] = l_managedObject.changedValues;
            // The self.savesInMainThreadOnly check below is to avoid core data errors such as "statement is still active" and "no database channel is available"
            // If updates are done in threads other than the main thread, then the original properties will not be available in the notification sent by this method
            NSDictionary *l_committedValuesDictionary = self.savesInMainThreadOnly ? [l_managedObject committedValuesForKeys:nil] : @{};
            self.IFA_managedObjectCommittedValuesDictionary[l_managedObject.ifa_stringId] = l_committedValuesDictionary;
        }
        for (NSManagedObject *l_managedObject in [self.managedObjectContext deletedObjects]) {
            // The self.savesInMainThreadOnly check below is to avoid core data errors such as "statement is still active" and "no database channel is available"
            // If updates are done in threads other than the main thread, then the original properties will not be available in the notification sent by this method
            NSDictionary *l_committedValuesDictionary = self.savesInMainThreadOnly ? [l_managedObject committedValuesForKeys:nil] : @{};
            self.IFA_managedObjectCommittedValuesDictionary[l_managedObject.ifa_stringId] = l_committedValuesDictionary;
        }
//        NSLog(@"self.IFA_managedObjectChangedValuesDictionary: %@", [self.IFA_managedObjectChangedValuesDictionary description]);
//        NSLog(@"self.IFA_managedObjectCommittedValuesDictionary: %@", [self.IFA_managedObjectCommittedValuesDictionary description]);
    }else if ([[aNotification name] isEqual:NSManagedObjectContextDidSaveNotification]) {

        NSMutableDictionary *l_entityUserInfoDict = [[NSMutableDictionary alloc] init];

        // Process inserted objects
        for (NSManagedObject *l_managedObject in [[aNotification userInfo] valueForKey:NSInsertedObjectsKey]) {

            NSString *l_entityName = [l_managedObject ifa_entityName];
            NSMutableDictionary *l_userInfoDict = [self userInfoForEntityName:l_entityName entityUserInfo:l_entityUserInfoDict];
            //            NSLog(@"class: %@", [[l_userInfoDict class] description]);
            //            NSLog(@"value: %@", [l_userInfoDict description]);
            [((NSMutableSet*) [l_userInfoDict valueForKey:IFAKeyInsertedObjects]) addObject:l_managedObject];

        }

        // Process updated objects
        for (NSManagedObject *l_managedObject in [[aNotification userInfo] valueForKey:NSUpdatedObjectsKey]) {

            NSString *l_entityName = [l_managedObject ifa_entityName];
            NSMutableDictionary *l_userInfoDict = [self userInfoForEntityName:l_entityName entityUserInfo:l_entityUserInfoDict];
            [((NSMutableSet*) [l_userInfoDict valueForKey:IFAKeyUpdatedObjects]) addObject:l_managedObject];
            ((NSMutableDictionary *) [l_userInfoDict valueForKey:IFAKeyUpdatedProperties])[l_managedObject.ifa_stringId] = self.IFA_managedObjectChangedValuesDictionary[l_managedObject.ifa_stringId];
            ((NSMutableDictionary *) [l_userInfoDict valueForKey:IFAKeyOriginalProperties])[l_managedObject.ifa_stringId] = self.IFA_managedObjectCommittedValuesDictionary[l_managedObject.ifa_stringId];

        }

        // Process deleted objects
        //        NSLog(@"processing deleted objects...");
        for (NSManagedObject *l_managedObject in [[aNotification userInfo] valueForKey:NSDeletedObjectsKey]) {

            //            NSLog(@"l_managedObject: %@", l_managedObject);
            NSString *l_entityName = [l_managedObject ifa_entityName];
            NSMutableDictionary *l_userInfoDict = [self userInfoForEntityName:l_entityName entityUserInfo:l_entityUserInfoDict];
            [((NSMutableSet*) [l_userInfoDict valueForKey:IFAKeyDeletedObjects]) addObject:l_managedObject];
            ((NSMutableDictionary *) [l_userInfoDict valueForKey:IFAKeyOriginalProperties])[l_managedObject.ifa_stringId] = self.IFA_managedObjectCommittedValuesDictionary[l_managedObject.ifa_stringId];
            //            NSLog(@"l_userInfoDict: %@", [l_userInfoDict description]);

        }

        // Send notifications
        for (NSString *l_entityName in [l_entityUserInfoDict allKeys]) {
            
//            NSLog(@"Notifying for %@", l_entityName);
            NSDictionary *l_userInfoDict = [l_entityUserInfoDict valueForKey:l_entityName];
            //            NSLog(@"l_userInfoDict: %@", l_userInfoDict);
            
            BOOL l_causeDataToGoStaleForEntity = NO;
            
            // Check deleted objects
            for (NSManagedObject *l_managedObject in l_userInfoDict[IFAKeyDeletedObjects]) {
                l_causeDataToGoStaleForEntity = [self.entityConfig shouldTriggerChangeNotificationForManagedObject:l_managedObject];
                if (l_causeDataToGoStaleForEntity) {
//                    NSLog(@"  shouldTriggerChangeNotification due to deleted object: %@", [l_managedObject description]);
//                    self.p_isPrivateQueueManagedObjectContextStale = YES;
                    break;
                }
            }
            
            if (!l_causeDataToGoStaleForEntity) {
                
                // Check inserted objects
                for (NSManagedObject *l_managedObject in l_userInfoDict[IFAKeyInsertedObjects]) {
                    l_causeDataToGoStaleForEntity = [self.entityConfig shouldTriggerChangeNotificationForManagedObject:l_managedObject];
                    if (l_causeDataToGoStaleForEntity) {
//                        NSLog(@"  shouldTriggerChangeNotification due to inserted object: %@", [l_managedObject description]);
//                        self.p_isPrivateQueueManagedObjectContextStale = YES;
                        break;
                    }
                }
                
                if (!l_causeDataToGoStaleForEntity) {
                    
                    // Check updated objects
                    NSDictionary *l_updatedPropertiesDict = l_userInfoDict[IFAKeyUpdatedProperties];
//                    NSLog(@"  l_updatedPropertiesDict: %@", [l_updatedPropertiesDict description]);
                    for (NSManagedObject *l_managedObject in l_userInfoDict[IFAKeyUpdatedObjects]) {
//                        NSLog(@"    l_managedObject: %@", [l_managedObject description]);
                        for (NSString *l_propertyName in [l_updatedPropertiesDict[l_managedObject.ifa_stringId] allKeys]) {
//                            NSLog(@"      l_propertyName: %@", l_propertyName);
                            l_causeDataToGoStaleForEntity = [self.entityConfig shouldTriggerChangeNotificationForProperty:l_propertyName inManagedObject:l_managedObject];
                            if (l_causeDataToGoStaleForEntity) {
//                                NSLog(@"  shouldTriggerChangeNotification due to updated object: %@, property: %@", [l_managedObject description], l_propertyName);
//                                self.p_isPrivateQueueManagedObjectContextStale = YES;
                                break;
                            }
                        }
                        if (l_causeDataToGoStaleForEntity) {
                            break;
                        }
                    }
                    
                }
                
            }
            
            if (l_causeDataToGoStaleForEntity) {

                NSNotification *notification = [NSNotification notificationWithName:IFANotificationPersistentEntityChange
                                                                             object:NSClassFromString(l_entityName)
                                                                           userInfo:l_userInfoDict];
                [[NSNotificationCenter defaultCenter] postNotification:notification];
//                NSLog(@"Notification sent for %@", l_entityName);
//                NSLog(@"  userInfo: %@", l_userInfoDict);

            }

        }

        //        NSLog(@"l_entityUserInfoDict: %@", l_entityUserInfoDict);

    }else{
        NSAssert(NO, @"Unexpected notification: %@", [aNotification name]);
    }
    
    //    NSLog(@" ");
    
}

- (NSError*)newErrorWithCode:(NSInteger)anErrorCode errorMessage:(NSString*)anErrorMessage{
	NSArray *keyArray = @[NSLocalizedDescriptionKey];
	NSArray *objArray = @[anErrorMessage];
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjects:objArray forKeys:keyArray];
	return [[NSError alloc] initWithDomain:IFAErrorDomainCommon code:anErrorCode userInfo:userInfo];
}

- (BOOL) validateUniqueKeysForManagedObject:(NSManagedObject *)aManagedObject error:(NSError**)anError{
	BOOL ok = YES;
	BOOL errorCreated = NO;
	NSArray *uniqueKeyArrays = [self.entityConfig uniqueKeysForManagedObject:aManagedObject];
	//NSLog(@"uniqueKeyArrays count: %lu", [uniqueKeyArrays count]);
	for(NSArray* uniqueKeyArray in uniqueKeyArrays){
		if ([uniqueKeyArray count]==1) {
			NSString *propertyName = [uniqueKeyArray objectAtIndex:0];
			if([aManagedObject valueForKey:propertyName]==NULL){
				// skip the check if the key has a single property and it is null (obviously only valid for optional properties) 
				continue;
			}
		}
		NSDictionary *keysAndValues = [aManagedObject dictionaryWithValuesForKeys:uniqueKeyArray];
		NSUInteger count = [self countEntity:[aManagedObject.class description] keysAndValues:keysAndValues];
		if (count==1) {	// it it finds only 1 it's ok because it's the managed object itself
			continue;
		}else{
            NSString *errorMessage;
            NSString *labelForKeys = [aManagedObject ifa_labelForKeys:uniqueKeyArray];
            if ([keysAndValues count]>1) {
                errorMessage = [NSString stringWithFormat:NSLocalizedStringFromTable(@"This combination of %@ already exists.\n", @"IFALocalizable", @"This combination of <FIELD_NAMES> already exists."), [labelForKeys lowercaseString]];
            } else {
                errorMessage = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ already exists.\n", @"IFALocalizable", @"<FIELD_NAME> already exists."), labelForKeys];
            }
			NSError *detailError = [self newErrorWithCode:IFAErrorPersistenceDuplicateKey
											  errorMessage:errorMessage];
			if (ok) {
				ok = NO;
				if(anError!=NULL){
					*anError = [IFAUIUtils newErrorContainerWithError:detailError];
					errorCreated = YES;
				}
			}else if (errorCreated) {
				[IFAUIUtils addError:detailError toContainer:*anError];
			}
		}
	}
	return ok;
}

-(BOOL)canValidationErrorBeIgnored:(NSError*)a_error forManagedObject:(NSManagedObject*)a_managedObject{
    if(a_error.code==NSValidationRelationshipDeniedDeleteError){
        NSDictionary *l_errorDict = [a_error userInfo];
        NSString *l_propertyName = [l_errorDict objectForKey:NSValidationKeyErrorKey];
//        NSLog(@"l_propertyName: %@", l_propertyName);
        NSRelationshipDescription *l_relationshipDescription = [[[NSEntityDescription entityForName:[a_managedObject ifa_entityName] inManagedObjectContext:[self currentManagedObjectContext]] relationshipsByName] valueForKey:l_propertyName];
        if (l_relationshipDescription.deleteRule==NSDenyDeleteRule) {
            return NO;
        }
    }else{
        return NO;
    }
    return YES;
}

- (NSString*)getMessageForErrorContainer:(NSError*)anErrorContainer withManagedObject:(NSManagedObject*)aManagedObject{
    
//    NSLog(@"aManagedObject: %@", [aManagedObject description]);
	
	NSArray* errors = nil;
	if([anErrorContainer code] == NSValidationMultipleErrorsError){
		errors = [anErrorContainer userInfo][NSDetailedErrorsKey];
	}else{
		errors = @[anErrorContainer];
	}
    
    NSMutableArray *l_deleteDeniedPropertyLabels = [NSMutableArray new];
	
	NSMutableString* message = [[NSMutableString alloc] initWithString:@""];
	NSMutableSet* propertiesAlreadyValidated = [[NSMutableSet alloc] init];
	for(NSError* error in errors){
        
        if ([self canValidationErrorBeIgnored:error forManagedObject:aManagedObject]) {
            continue;
        }
		
		NSDictionary* errorDictionary = [error userInfo];
		NSString* propertyName = errorDictionary[NSValidationKeyErrorKey];
//        NSLog(@"propertyName: %@", propertyName);
		
		if([error domain]==NSCocoaErrorDomain){
            
			switch ([error code]) {
				case NSValidationMissingMandatoryPropertyError:
				case NSValidationStringTooShortError:	
				case NSValidationStringPatternMatchingError:
				case NSValidationNumberTooSmallError:
				case NSValidationNumberTooLargeError:	
				case NSValidationRelationshipDeniedDeleteError:
                {
                    if (![propertiesAlreadyValidated containsObject:propertyName]) {
                        NSString *l_propertyLabel = [self.entityConfig labelForProperty:propertyName inObject:aManagedObject];
//                        NSLog(@"l_propertyLabel");
                        switch ([error code]) {
                            case NSValidationMissingMandatoryPropertyError:
                            case NSValidationStringTooShortError:	
                            case NSValidationStringPatternMatchingError:
                                if (![message ifa_isEmpty]) {
                                    [message appendString:@"\n"];
                                }
                                [message appendFormat:NSLocalizedStringFromTable(@"%@ is required.", @"IFALocalizable", @"<FIELD_NAME> is required."), l_propertyLabel];
                                break;
                            case NSValidationNumberTooSmallError:
                            case NSValidationNumberTooLargeError:
                                if (![message ifa_isEmpty]) {
                                    [message appendString:@"\n"];
                                }
                                [message appendFormat:NSLocalizedStringFromTable(@"%@ is outside allowed range.", @"IFALocalizable", @"<FIELD_NAME> is outside allowed range."), l_propertyLabel];
                                break;
                            case NSValidationRelationshipDeniedDeleteError:
                                [l_deleteDeniedPropertyLabels addObject:l_propertyLabel];
                                break;
                            default:
                                NSAssert(NO, @"Unexpected error code: %ld", (long)[error code]);
                                break;
                        }
                        [propertiesAlreadyValidated addObject:propertyName];
                    }
                    break;
                }
                default:
					[IFAUIUtils handleUnrecoverableError:error];
                    break;
            }
            
		}else if([error domain]== IFAErrorDomainCommon){
			[message appendString:[error localizedDescription]];
		}else{
			[IFAUIUtils handleUnrecoverableError:error];
		}
	}
	
    if ([l_deleteDeniedPropertyLabels count]>0) {
        if (![message ifa_isEmpty]) {
            [message appendString:@"\n"];
        }
        [message appendString:NSLocalizedStringFromTable(@"One or more associations exist with the following: ", @"IFALocalizable", nil)];
        for (NSUInteger i=0; i<[l_deleteDeniedPropertyLabels count]; i++) {
            if (i>0) {
                if (i+1==[l_deleteDeniedPropertyLabels count]) {
                    [message appendString:NSLocalizedStringFromTable(@" and ", @"IFALocalizable", @"final separator in a list of names")];
                }else{
                    [message appendString:NSLocalizedStringFromTable(@", ", @"IFALocalizable", @"separator in a list of names")];
                }
            }
            [message appendString:l_deleteDeniedPropertyLabels[i]];
        }
    }
	
	return message;
}

- (void)handleCoreDataError:(NSError *)a_errorContainer withManagedObject:(NSManagedObject *)a_managedObject
                 alertTitle:(NSString *)a_alertTitle alertPresenter:(UIViewController *)a_alertPresenter{
//    NSLog(@"Handling core data error: %@", [anErrorContainer description]);
    NSString *title = a_alertTitle ? a_alertTitle : NSLocalizedStringFromTable(@"Validation Error", @"IFALocalizable", nil);
	NSString *message = [self getMessageForErrorContainer:a_errorContainer withManagedObject:a_managedObject];
    [a_alertPresenter ifa_presentAlertControllerWithTitle:title message:message];
}

- (BOOL)validateForDelete:(NSManagedObject *)aManagedObject alertPresenter:(UIViewController *)a_alertPresenter{

	NSError *l_errorContainer;

	// Core data model validation
	if ([aManagedObject validateForDelete:&l_errorContainer]) {

		return YES;

	}else{
        
        NSUInteger l_errorCount = 0;

        NSArray* l_errors = nil;
        if([l_errorContainer code] == NSValidationMultipleErrorsError){
            l_errors = l_errorContainer.userInfo[NSDetailedErrorsKey];
        }else{
            l_errors = @[l_errorContainer];
        }
        
        for(NSError* l_error in l_errors){
            if (![self canValidationErrorBeIgnored:l_error forManagedObject:aManagedObject]) {
                l_errorCount++;
            }
        }
        
//        NSLog(@"l_errorCount: %u", l_errorCount);
        if (l_errorCount==0) {
            return YES;
        }
        
    }

	[self handleCoreDataError:l_errorContainer withManagedObject:aManagedObject alertTitle:NSLocalizedStringFromTable(@"Deletion Not Allowed", @"IFALocalizable", nil) alertPresenter:a_alertPresenter];
	return NO;

}

- (BOOL)isInMemoryListSortForEntity:(NSString *)a_entityName
                usedForRelationship:(BOOL)a_usedForRelationship {
    BOOL l_isInMemory = [self.entityConfig isInMemoryListSortForEntity:a_entityName
                                                     usedForRelationship:a_usedForRelationship];
//    NSLog(@"isInMemoryListSortForEntity %@: %u", a_entityName, l_isInMemory);
    return l_isInMemory;
}

/*
 Find all instances of a given entity (non-system) sorted according to configuration
 */
- (NSMutableArray *)findAllForNonSystemEntity:(NSString *)entityName
                        includePendingChanges:(BOOL)a_includePendingChanges
                           includeSubentities:(BOOL)a_includeSubentities
                          usedForRelationship:(BOOL)a_usedForRelationship {
    NSFetchRequest *l_fetchRequest = [self findAllFetchRequest:entityName
                                         includePendingChanges:a_includePendingChanges
                                             usedForRelationship:a_usedForRelationship];
    l_fetchRequest.includesSubentities = a_includeSubentities;
    NSMutableArray *l_array = [self inMemorySortObjects:[self executeFetchRequestMutable:l_fetchRequest]
                                          ofEntityNamed:entityName
                                    usedForRelationship:a_usedForRelationship];
//    NSLog(@"findAllForNonSystemEntity for %@: %@", ifa_entityName, [l_array description]);
    return l_array;
}

/*
 Find all instances of a given system entity sorted according to configuration.
 */
- (NSMutableArray *)findAllForSystemEntity:(NSString *)entityName
                     includePendingChanges:(BOOL)a_includePendingChanges
                        includeSubentities:(BOOL)a_includeSubentities
                       usedForRelationship:(BOOL)a_usedForRelationship {
    NSFetchRequest *request = [self findAllFetchRequest:entityName
                                  includePendingChanges:a_includePendingChanges
                                      usedForRelationship:a_usedForRelationship];
    request.includesSubentities = a_includeSubentities;
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"systemUseOnly == %@", @0];
    [request setPredicate:predicate];
    return [self inMemorySortObjects:[self executeFetchRequestMutable:request]
                       ofEntityNamed:entityName
                 usedForRelationship:a_usedForRelationship];
}

-(NSPredicate*)predicateForKeysAndValues:(NSDictionary*)aDictionary{
    
	NSMutableString *predicateString = [NSMutableString string];
	NSArray *keys = [aDictionary allKeys];
	NSMutableArray *predicateArguments = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < [keys count]; i++) {
		NSString *propertyName = [keys objectAtIndex:i];
		id propertyValue = [aDictionary objectForKey:propertyName];
        //		NSLog(@"propertyName: %@", propertyName);
		//NSLog(@"propertyValue: %p", propertyValue);
		//NSLog(@"NSNull: %p", [NSNull null]);
		[predicateArguments addObject:propertyName];
		if (i>0) {
			[predicateString appendString:@" and "];
		}
		if (propertyValue==[NSNull null]) {
			[predicateString appendString:(NSString *)@"%K = NULL"];
		}else {
			[predicateArguments addObject:propertyValue];
            //			[predicateString appendString:(NSString *)@"%K matches[cd] %@"];
			[predicateString appendString:(NSString *)@"%K = %@"];
		}
        
	}
    
    return [NSPredicate predicateWithFormat:predicateString argumentArray:predicateArguments];
    
}

- (BOOL) systemDbTablesLoaded{
	return [(NSString*)[self metadataValueForKey:METADATA_KEY_SYSTEM_DB_TABLES_LOADED] isEqualToString:METADATA_VALUE_SYSTEM_DB_TABLES_LOADED];
}

- (NSUInteger) systemDbTablesVersion{
    id l_value = [self metadataValueForKey:METADATA_KEY_SYSTEM_DB_TABLES_VERSION];
    return l_value ? [(NSNumber*)l_value integerValue] : 0;
}

- (void) setSystemDbTablesVersion:(NSUInteger)a_version{
	[self setMetadataValue:METADATA_VALUE_SYSTEM_DB_TABLES_LOADED forKey:METADATA_KEY_SYSTEM_DB_TABLES_LOADED];
	[self setMetadataValue:@(a_version) forKey:METADATA_KEY_SYSTEM_DB_TABLES_VERSION];
}

- (NSPersistentStore *)IFA_addPersistentStoreWithType:(NSString *)a_persistentStoreType
                                               andUrl:(NSURL *)a_persistentStoreUrl
                         toPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)a_persistentStoreCoordinator
                                             readOnly:(BOOL)a_readOnly {
    NSMutableDictionary *options = [@{
            NSMigratePersistentStoresAutomaticallyOption : @(YES),
            NSInferMappingModelAutomaticallyOption : @(YES),
    } mutableCopy];
    if (a_readOnly) {
        options[NSReadOnlyPersistentStoreOption] = @(YES);
    }
    NSError *error;
    NSPersistentStore *persistentStore = [a_persistentStoreCoordinator addPersistentStoreWithType:a_persistentStoreType
                                                                                    configuration:nil
                                                                                              URL:a_persistentStoreUrl
                                                                                          options:options
                                                                                            error:&error];
    if (!persistentStore) {
        [IFAUIUtils handleUnrecoverableError:error];
    }
    return persistentStore;
}

- (NSManagedObjectModel *)IFA_managedObjectModelForResourceNamed:(NSString *)a_resourceName
                                                         version:(NSNumber *)a_version
                                                        inBundle:(NSBundle *)a_resourceBundle {
    NSMutableString *resourceName = [[NSMutableString alloc] initWithString:a_resourceName];
    if (a_version) {
        [resourceName appendString:@" "];
        [resourceName appendString:a_version.stringValue];
    }
    NSBundle *bundle = a_resourceBundle ?:[NSBundle mainBundle];
    NSString *path = [bundle pathForResource:resourceName
                                      ofType:@"momd"];
    NSURL *momURL = [NSURL fileURLWithPath:path];
    NSManagedObjectModel *managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:momURL];
    return managedObjectModel;
}

- (NSURL *)
IFA_sqlStoreUrlForDatabaseResourceName:(NSString *)a_databaseResourceName
    databaseResourceRelativeFolderPath:(NSString *)a_databaseResourceRelativeFolderPath
    securityApplicationGroupIdentifier:(NSString *)a_securityApplicationGroupIdentifier {
    NSURL *storeBaseUrl = [self IFA_sqlStoreBaseUrlWithSecurityApplicationGroupIdentifier:a_securityApplicationGroupIdentifier];
    if (a_databaseResourceRelativeFolderPath) {
        storeBaseUrl = [NSURL URLWithString:a_databaseResourceRelativeFolderPath
                              relativeToURL:storeBaseUrl];
    }
    return [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                          relativeToUrl:storeBaseUrl];
}

- (NSURL *)IFA_sqlStoreUrlForDatabaseResourceName:(NSString *)a_databaseResourceName
               databaseResourceAbsoluteFolderPath:(NSString *)a_databaseResourceAbsoluteFolderPath {
    NSURL *dataStoreBaseUrl = [NSURL fileURLWithPath:a_databaseResourceAbsoluteFolderPath isDirectory:YES];
    return [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                          relativeToUrl:dataStoreBaseUrl];
}

- (NSURL *)IFA_sqlStoreUrlForDatabaseResourceName:(NSString *)a_databaseResourceName
                                    relativeToUrl:(NSURL *)baseUrl {
    NSString *lastUrlPathComponent = [NSString stringWithFormat:@"%@.sqlite",
                                                                a_databaseResourceName];
    NSURL *sqlStoreUrl = [NSURL URLWithString:lastUrlPathComponent
                                relativeToURL:baseUrl];
    return sqlStoreUrl;
}

- (NSURL *)IFA_sqlStoreBaseUrlWithSecurityApplicationGroupIdentifier:(NSString *)a_securityApplicationGroupIdentifier {
    NSURL *storeBaseUrl;
    if (a_securityApplicationGroupIdentifier) {
        storeBaseUrl = [NSURL URLWithString:@"CoreData/"
                              relativeToURL:[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:a_securityApplicationGroupIdentifier]];
    } else {
        storeBaseUrl = [NSURL fileURLWithPath:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject] isDirectory:YES];
    }
    return storeBaseUrl;
}

- (void)IFA_willPerformCrudSaveForObject:(NSManagedObject *)object {
    if ([self.delegate respondsToSelector:@selector(persistenceManager:willPerformCrudSaveForObject:)]) {
        [self.delegate persistenceManager:self
             willPerformCrudSaveForObject:object];
    }
}

- (void)IFA_removeObservers {
    if (self.IFA_observingManagedObjectContext) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self.IFA_observingManagedObjectContext = NO;
    }
}

#pragma mark - Public

- (void) resetEditSession{
	self.isCurrentManagedObjectDirty = NO;
}

- (BOOL)validateValue:(id *)a_value forProperty:(NSString *)a_propertyName inManagedObject:a_managedObject
       alertPresenter:(UIViewController *)a_alertPresenter{
	NSError* errorContainer;
	if([a_managedObject validateValue:a_value forKey:a_propertyName error:&errorContainer]){
		return YES;
	}else {
        [self handleCoreDataError:errorContainer withManagedObject:a_managedObject alertTitle:nil
                   alertPresenter:a_alertPresenter];
		return NO;
	}
}

- (BOOL) save{
    return [self saveManagedObjectContext:[self currentManagedObjectContext]];
}

- (BOOL) saveManagedObjectContext:(NSManagedObjectContext*)a_moc{
    
	NSError *error;
	if([a_moc save:&error]){
		[self resetEditSession];
		return YES;
	}else{
		[IFAUIUtils handleUnrecoverableError:error];
		return NO;
	}
    
}

- (BOOL)saveMainManagedObjectContext{
    return [self saveManagedObjectContext:self.managedObjectContext];
}

- (BOOL)saveObject:(NSManagedObject *)aManagedObject validationAlertPresenter:(UIViewController *)a_validationAlertPresenter{

    [self IFA_willPerformCrudSaveForObject:aManagedObject];

	if([self validateForSave:aManagedObject validationAlertPresenter:a_validationAlertPresenter]){

        NSString *entityName = [aManagedObject ifa_entityName];

		// Manage sequence if this entity's list can be reordered by the user
		if ([self.entityConfig listReorderAllowedForObject:aManagedObject]) {
            NSArray* all = [self findAllForEntity:entityName
                            includePendingChanges:YES];
			for (int i = 0; i < [all count]; i++) {
                id managedObject = all[i];
                NSNumber *seq = [NSNumber numberWithUnsignedInt:((i+1)*2)];
                [managedObject setValue:seq forKey:@"seq"];
			}
		}

        // Set last update date if required
        NSString *lastUpdateDatePropertyName = [self.entityConfig lastUpdateDatePropertyNameForEntity:entityName];
        if (lastUpdateDatePropertyName) {
            [aManagedObject setValue:[NSDate date]
                              forKey:lastUpdateDatePropertyName];
        }

		return [self save];
        
	}else {
		return NO;
	}
}

/*
 Delete a managed object.
 */
- (BOOL)deleteObject:(NSManagedObject *)aManagedObject validationAlertPresenter:(UIViewController *)a_validationAlertPresenter {
    
	if([self validateForDelete:aManagedObject alertPresenter:a_validationAlertPresenter]){
        
        // Run pre-delete method
        //        NSLog(@"Running pre-delete method...");
        [aManagedObject ifa_willDelete];
        //        NSLog(@"Done");
		
		NSManagedObjectContext *moc = self.currentManagedObjectContext;
		[moc deleteObject:aManagedObject];
        
        // Run post-delete method
        //            NSLog(@"Running post-delete method...");
        [aManagedObject ifa_didDelete];
        //            NSLog(@"Done");
        
        return YES;
		
	}else {
		return NO;
	}
    
}

/*
 Delete a managed object and save.
 */
- (BOOL)deleteAndSaveObject:(NSManagedObject *)aManagedObject validationAlertPresenter:(UIViewController *)a_validationAlertPresenter{

    [self IFA_willPerformCrudSaveForObject:aManagedObject];
    
	if([self validateForDelete:aManagedObject alertPresenter:a_validationAlertPresenter]){
        
        // Run pre-delete method
        //        NSLog(@"Running pre-delete method...");
        [aManagedObject ifa_willDelete];
        //        NSLog(@"Done");
		
		NSManagedObjectContext *moc = self.currentManagedObjectContext;
		[moc deleteObject:aManagedObject];
		NSError *error;
		if([moc save:&error]){
            
			[self resetEditSession];
            
            // Run post-delete method
            //            NSLog(@"Running post-delete method...");
            [aManagedObject ifa_didDelete];
            //            NSLog(@"Done");
            
			return YES;
            
		}else {
            
			[self handleCoreDataError:error withManagedObject:aManagedObject alertTitle:nil alertPresenter:a_validationAlertPresenter];
			return NO;
            
		}
		
	}else {
		return NO;
	}
    
}

/**
 Roll back persistence changes
 */
- (void) rollback{
	[self resetEditSession];
	[[self currentManagedObjectContext] rollback];
}

/*
 Undo persistence changes
 */
//- (void) undo{
//	[[self m_managedObjectContext] undo];
//}

/*
 Return new managed object instance
 */
- (NSManagedObject *)instantiate:(NSString *)entityName{

    NSManagedObject *l_mo = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:[self currentManagedObjectContext]];

    NSError *l_error;
    NSManagedObjectContext *l_moc = [self currentManagedObjectContext];
    if(![l_moc obtainPermanentIDsForObjects:@[l_mo]
                                      error:&l_error]){
        [IFAUIUtils handleUnrecoverableError:l_error];
    };

    // Set UUID if required
    NSString *uuidPropertyName = [self.entityConfig uuidPropertyNameForEntity:entityName];
    if (uuidPropertyName) {
        [l_mo setValue:[IFAUtils generateUuid]
                forKey:uuidPropertyName];
    }

    // Set last update date if required
    NSString *lastUpdateDatePropertyName = [self.entityConfig lastUpdateDatePropertyNameForEntity:entityName];
    if (lastUpdateDatePropertyName) {
        [l_mo setValue:[NSDate date]
                forKey:lastUpdateDatePropertyName];
    }

	return l_mo;

}

- (NSMutableArray *) findAllForEntity:(NSString *)entityName{
    return [self findAllForEntity:entityName includePendingChanges:NO];
}

/*
 Find all instances of a given entity sorted according to configuration.
 This method will figure out whether the entity is a system entity or not and dispatch to the appropriate implementation.
 */
- (NSMutableArray *) findAllForEntity:(NSString *)entityName includePendingChanges:(BOOL)a_includePendingChanges{
    return [self findAllForEntity:entityName includePendingChanges:a_includePendingChanges includeSubentities:YES];
}

- (NSMutableArray *) findAllForEntity:(NSString *)entityName includePendingChanges:(BOOL)a_includePendingChanges includeSubentities:(BOOL)a_includeSubentities {
    return [self findAllForEntity:entityName
            includePendingChanges:a_includePendingChanges
               includeSubentities:a_includeSubentities
              usedForRelationship:NO];
}

- (NSMutableArray *) findAllForEntity:(NSString *)entityName includePendingChanges:(BOOL)a_includePendingChanges includeSubentities:(BOOL)a_includeSubentities usedForRelationship:(BOOL)a_usedForRelationship{
	if ([self isSystemEntityForEntity:entityName]) {
		//NSLog(@"system entity: %@", ifa_entityName);
		return [self findAllForSystemEntity:entityName
                      includePendingChanges:a_includePendingChanges
                         includeSubentities:a_includeSubentities
                        usedForRelationship:a_usedForRelationship];
	}else {
		//NSLog(@"ANY entity: %@", ifa_entityName);
		return [self findAllForNonSystemEntity:entityName
                         includePendingChanges:a_includePendingChanges
                            includeSubentities:a_includeSubentities
                           usedForRelationship:a_usedForRelationship];
	}

}

- (void)deleteAllAndSaveForEntity:(NSString *)entityName
         validationAlertPresenter:(UIViewController *)a_validationAlertPresenter{
    [self deleteAllForEntity:entityName
    validationAlertPresenter:a_validationAlertPresenter];
    [self save];
}

- (void)deleteAllForEntity:(NSString *)a_entityName
  validationAlertPresenter:(UIViewController *)a_validationAlertPresenter {
    for (NSManagedObject *l_managedObject in [self findAllForEntity:a_entityName]) {
        [l_managedObject ifa_deleteWithValidationAlertPresenter:a_validationAlertPresenter];
    }
}

- (NSManagedObject *) findSystemEntityById:(NSUInteger)anId entity:(NSString *)anEntityName{
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"systemEntityId == %@", [NSNumber numberWithUnsignedInteger:anId]];
	return [self fetchSingleWithPredicate:predicate entity:anEntityName];
}

- (NSManagedObject *) findByName:(NSString*)aName entity:(NSString *)anEntityName{
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name == %@", aName]; 
	return [self fetchSingleWithPredicate:predicate entity:anEntityName];
}

- (NSManagedObject *) findById:(NSManagedObjectID*)anObjectId{
    NSManagedObject *l_managedObject = nil;
    if (anObjectId) {
        l_managedObject = [[self currentManagedObjectContext] existingObjectWithID:anObjectId error:nil];
    }
    return l_managedObject;
}

- (NSManagedObject *) findByStringId:(NSString*)aStringId{
    NSManagedObjectID *l_managedObjectId = [self.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:aStringId]];
    return [self findById:l_managedObjectId];
}

- (NSManagedObject *)findByUuid:(NSString *)uuid entityName:(NSString *)entityName {
    if (uuid) {
        NSString *uuidPropertyName = [self.entityConfig uuidPropertyNameForEntity:entityName];
        if (uuidPropertyName) {
            return [self findSingleByKeysAndValues:@{uuidPropertyName: uuid}
                                            entity:entityName];
        } else {
            return nil;
        }
    } else {
        return nil;
    }
}

-(NSArray*)findByKeysAndValues:(NSDictionary*)aDictionary entity:(NSString *)anEntityName{
    return [self fetchWithPredicate:[self predicateForKeysAndValues:aDictionary] entity:anEntityName];
}

-(NSManagedObject*)findSingleByKeysAndValues:(NSDictionary*)aDictionary entity:(NSString *)anEntityName{
    NSArray *l_result = [self findByKeysAndValues:aDictionary entity:anEntityName];
    NSAssert(l_result.count<=1, @"Unexpected count: %lu", (unsigned long)l_result.count);
    if (l_result.count==0) {
        return nil;
    }else{
        return l_result[0];
    }
}

- (NSUInteger) countEntity:(NSString*)entityName {
    return [self countEntity:entityName
               keysAndValues:nil];
}

- (NSUInteger) countEntity:(NSString*)anEntityName keysAndValues:(NSDictionary*)aDictionary{
    NSPredicate *predicate = nil;
    if (aDictionary) {
        predicate = [self predicateForKeysAndValues:aDictionary];
    }
    return [self countEntity:anEntityName
               withPredicate:predicate];
}

- (NSUInteger) countEntity:(NSString*)entityName
             withPredicate:(NSPredicate *)predicate {
    NSFetchRequest * request = [[NSFetchRequest alloc] init];
    [request setEntity:[NSEntityDescription entityForName:entityName
                                   inManagedObjectContext:[self currentManagedObjectContext]]];
    if (predicate) {
        [request setPredicate:predicate];
    }
    //NSLog(@"count request: %@", [request description]);
    NSError *error;
    NSUInteger count = [[self currentManagedObjectContext] countForFetchRequest:request error:&error];
    if (count==NSNotFound) {
        [IFAUIUtils handleUnrecoverableError:error];
    }
    return count;
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
						 entity:(NSString*)anEntityName{
	return [self fetchWithPredicate:aPredicate sortDescriptor:nil entity:anEntityName];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate
						 entity:(NSString*)anEntityName
                          block:(void (^)(NSFetchRequest *aFetchRequest))aBlock{
    return [self fetchWithPredicate:aPredicate sortDescriptors:nil entity:anEntityName limit:0 countOnly:NO block:aBlock];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
						 entity:(NSString*)anEntityName
                      countOnly:(BOOL)aCountOnlyFlag{
    return [self fetchWithPredicate:aPredicate sortDescriptors:nil entity:anEntityName limit:0 countOnly:aCountOnlyFlag];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
				 sortDescriptor:(NSSortDescriptor*)aSortDescriptor
						 entity:(NSString*)anEntityName{
	return [self fetchWithPredicate:aPredicate sortDescriptors:aSortDescriptor?@[aSortDescriptor]:nil entity:anEntityName];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
				 sortDescriptor:(NSSortDescriptor*)aSortDescriptor
						 entity:(NSString*)anEntityName
                          limit:(NSUInteger)aLimit{
	return [self fetchWithPredicate:aPredicate sortDescriptors:aSortDescriptor?@[aSortDescriptor]:nil entity:anEntityName limit:aLimit];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
				sortDescriptors:(NSArray*)aSortDescriptorArray
						 entity:(NSString*)anEntityName{
    return [self fetchWithPredicate:aPredicate sortDescriptors:aSortDescriptorArray entity:anEntityName limit:0];
}


- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
				sortDescriptors:(NSArray*)aSortDescriptorArray
						 entity:(NSString*)anEntityName
                          limit:(NSUInteger)aLimit{
    return [self fetchWithPredicate:aPredicate sortDescriptors:aSortDescriptorArray entity:anEntityName limit:aLimit countOnly:NO];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate 
				sortDescriptors:(NSArray*)aSortDescriptorArray
						 entity:(NSString*)anEntityName
                          limit:(NSUInteger)aLimit
                      countOnly:(BOOL)aCountOnlyFlag{
    return [self fetchWithPredicate:aPredicate sortDescriptors:aSortDescriptorArray entity:anEntityName limit:aLimit countOnly:aCountOnlyFlag block:nil];
}

- (NSArray*) fetchWithPredicate:(NSPredicate*)aPredicate
                sortDescriptors:(NSArray*)aSortDescriptorArray
                         entity:(NSString*)anEntityName
                          limit:(NSUInteger)aLimit
                      countOnly:(BOOL)aCountOnlyFlag
                          block:(void (^)(NSFetchRequest *aFetchRequest))aBlock{
    
    // Configure fetch request
	NSFetchRequest *request = [self fetchRequestWithPredicate:aPredicate sortDescriptors:aSortDescriptorArray entity:anEntityName limit:aLimit countOnly:aCountOnlyFlag];
    
    // Customisation block
    if (aBlock) {
        aBlock(request);
    }
	
	// Execute fetch request
	NSArray *resultArray = [self executeFetchRequestMutable:request];
    
    
    return resultArray;
    
}

- (NSFetchedResultsController*) fetchControllerWithPredicate:(NSPredicate*)aPredicate 
                                              sortDescriptor:(NSSortDescriptor*)aSortDescriptor
                                                      entity:(NSString*)anEntityName
                                          sectionNameKeyPath:(NSString *)aSectionNameKeyPath
                                                   cacheName:(NSString *)aCacheName{
    return [self fetchControllerWithPredicate:aPredicate sortDescriptors:aSortDescriptor?@[aSortDescriptor]:nil entity:anEntityName sectionNameKeyPath:aSectionNameKeyPath cacheName:aCacheName];
}

- (NSFetchedResultsController*) fetchControllerWithPredicate:(NSPredicate*)aPredicate 
                                             sortDescriptors:(NSArray*)aSortDescriptorArray
                                                      entity:(NSString*)anEntityName
                                          sectionNameKeyPath:(NSString *)aSectionNameKeyPath
                                                   cacheName:(NSString *)aCacheName{
	
	// Fetch request
	NSFetchRequest *l_request = [[NSFetchRequest alloc] init];
	if (aPredicate) {
		[l_request setPredicate:aPredicate];
	}
	if(aSortDescriptorArray){
		[l_request setSortDescriptors:aSortDescriptorArray]; 
	}
	
	// Entity description
	NSEntityDescription *l_entityDescription = [NSEntityDescription entityForName:anEntityName inManagedObjectContext:[self currentManagedObjectContext]];
	[l_request setEntity:l_entityDescription];
	
	// Fetched results controller
    NSFetchedResultsController *l_controller = [[NSFetchedResultsController alloc] initWithFetchRequest:l_request managedObjectContext:[self currentManagedObjectContext] sectionNameKeyPath:aSectionNameKeyPath cacheName:aCacheName];
    
    return l_controller;
    
}

- (NSManagedObject*) fetchSingleWithPredicate:(NSPredicate*)aPredicate entity:(NSString*)anEntityName{
	NSArray *resultArray = [self fetchWithPredicate:aPredicate sortDescriptor:nil entity:anEntityName];
	NSUInteger count = [resultArray count];
	if (count>1) {
		NSAssert(NO, @"Unexpected entity count for single fetch: %lu", (unsigned long)count);
	}else if (count==1) {
		return [resultArray objectAtIndex:0];
	}
	return nil;
}

- (NSManagedObject*) fetchSingleForEntity:(NSString*)anEntityName{
    return [self fetchSingleWithPredicate:nil entity:anEntityName];
}

- (id)fetchWithExpression:(NSExpression *)anExpression
               resultType:(NSAttributeType)aResultType
                   entity:(NSString*)anEntityName{
	
	// Fetch request
	NSFetchRequest *request = [[NSFetchRequest alloc] init];
	[request setResultType:NSDictionaryResultType];
	
	// Entity description
	NSEntityDescription *entityDescription = [NSEntityDescription entityForName:anEntityName inManagedObjectContext:[self currentManagedObjectContext]];
	[request setEntity:entityDescription];
	
	// Result property name
	NSString *resultPropertyName = @"result";
	
	// Expression description 
	NSExpressionDescription *expressionDescription = [[NSExpressionDescription alloc] init];
	[expressionDescription setName:resultPropertyName]; 
	[expressionDescription setExpression:anExpression]; 
	[expressionDescription setExpressionResultType:aResultType];
	[request setPropertiesToFetch:@[expressionDescription]];
	
	// Execute fetch request
	NSMutableArray *resultArray = [self executeFetchRequestMutable:request];
	
	return [resultArray[0] valueForKey:resultPropertyName];
	
}

- (NSDictionary*)IFA_metadata {
	return [[self persistentStore] metadata];
}

- (void) setIFA_metadata:(NSDictionary*)aMetadataDictionary{
	[[self persistentStore] setMetadata:aMetadataDictionary];
}

- (id) metadataValueForKey:(NSString *)aKey{
	return [self.IFA_metadata valueForKey:aKey];
}

- (void) setMetadataValue:(id)aValue forKey:(NSString *)aKey{
	NSMutableDictionary *mutableMetadataDictionary = [self.IFA_metadata mutableCopy];
	[mutableMetadataDictionary setValue:aValue forKey:aKey];
	[self setIFA_metadata:mutableMetadataDictionary];
}

- (NSPersistentStore*) persistentStore{
    NSArray *persistentStores = self.persistentStoreCoordinator.persistentStores;
    NSAssert(persistentStores.count==1, @"Unexpected persistent store count: %lu", (unsigned long)persistentStores.count);
    return persistentStores[0];
}

- (BOOL)isSystemEntityForEntity:(NSString*)anEntityName{
	return [anEntityName hasPrefix:@"S_"];
}

- (NSArray *)listSortDescriptorsForEntity:(NSString *)a_entityName {
    return [self listSortDescriptorsForEntity:a_entityName
                          usedForRelationship:NO];
}

- (NSArray *)listSortDescriptorsForEntity:(NSString *)a_entityName
                      usedForRelationship:(BOOL)a_usedForRelationship {
    NSMutableArray *sortDescriptors = [NSMutableArray array];
    NSSortDescriptor *sortDescriptor;
    NSArray *listSortProperties = [self.entityConfig listSortPropertiesForEntity:a_entityName
                                                             usedForRelationship:a_usedForRelationship];
    if (listSortProperties.count) {
        // The list's sort order is dictated by the configuration
        for (NSDictionary *sortItem in listSortProperties) {
            NSString *keyPath = [sortItem objectForKey:@"name"];
            //            NSLog(@"keyPath: %@", keyPath);
            BOOL ascending = [[sortItem objectForKey:@"ascending"] boolValue];
            Class l_propertyClass = [IFAUtils classForPropertyNamed:keyPath
                                                       inClassNamed:a_entityName];
            //            NSLog(@"l_propertyClass: %@", [l_propertyClass description]);
            if ([l_propertyClass isSubclassOfClass:[NSString class]]) {
                sortDescriptor = [[NSSortDescriptor alloc] initWithKey:keyPath
                                                             ascending:ascending
                                                              selector:NSSelectorFromString(@"localizedCaseInsensitiveCompare:")];
                //                NSLog(@"  USING localised case insensitive compare...");
            } else {
                sortDescriptor = [[NSSortDescriptor alloc] initWithKey:keyPath
                                                             ascending:ascending];
                //                NSLog(@"  NOT using localised case insensitive compare...");
            }
            [sortDescriptors addObject:sortDescriptor];
        }
    } else if ([self.entityConfig listReorderAllowedForEntity:a_entityName]) {
        // The list's sort order is controlled by the user
        sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"seq"
                                                     ascending:YES];
        [sortDescriptors addObject:sortDescriptor];
    } else if ([self isSystemEntityForEntity:a_entityName]) {
        // Falls back to the default sort order for system entities
        sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"index"
                                                     ascending:YES];
        [sortDescriptors addObject:sortDescriptor];
        sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"name"
                                                     ascending:YES];  // fallback to name
        [sortDescriptors addObject:sortDescriptor];
    }
    return sortDescriptors;
}

- (void)performOnMainManagedObjectContextQueue:(void (^)(void))a_block{
    [self performOnQueueOfManagedObjectContext:self.managedObjectContext
                                         block:a_block];
}

- (void)performAndWaitOnMainManagedObjectContextQueue:(void (^)(void))a_block{
    [self performAndWaitOnQueueOfManagedObjectContext:self.managedObjectContext
                                                block:a_block];
}

- (void)performOnQueueOfManagedObjectContext:(NSManagedObjectContext *)a_managedObjectContext
                                       block:(void (^)(void))a_block {
    [a_managedObjectContext performBlock:[self IFA_wrapperForBlock:a_block managedObjectContext:a_managedObjectContext]];
}

- (void)performAndWaitOnQueueOfManagedObjectContext:(NSManagedObjectContext *)a_managedObjectContext
                                              block:(void (^)(void))a_block {
    [a_managedObjectContext performBlockAndWait:[self IFA_wrapperForBlock:a_block
                                                     managedObjectContext:a_managedObjectContext]];
}

- (void)performOnCurrentThreadForMainManagedObjectContext:(void (^)(void))a_block {
    [self IFA_wrapperForBlock:a_block
         managedObjectContext:self.managedObjectContext]();
}

- (void)performOnCurrentThreadWithManagedObjectContext:(NSManagedObjectContext *)a_managedObjectContext
                                                 block:(void (^)(void))a_block {
    [self IFA_wrapperForBlock:a_block
         managedObjectContext:a_managedObjectContext]();
}

-(NSMutableArray*)managedObjectsForIds:(NSArray*)a_managedObjectIds{
    NSMutableArray *l_objects = [NSMutableArray new];
    for (NSManagedObjectID *l_managedObjectId in a_managedObjectIds) {
        NSError *l_error;
        NSManagedObject *l_mo = [[self currentManagedObjectContext] existingObjectWithID:l_managedObjectId error:&l_error];
        if (l_mo) {
            [l_objects addObject:l_mo];
        }else{
            [IFAUIUtils handleUnrecoverableError:l_error];
        }
    }
    return l_objects;
}

- (BOOL)migratePersistentStoreFromPrivateContainerToGroupContainerIfRequiredWithDatabaseResourceName:(NSString *)a_databaseResourceName
                                                                      managedObjectModelResourceName:(NSString *)a_managedObjectModelResourceName
                                                                    managedObjectModelResourceBundle:(NSBundle *)a_managedObjectModelResourceBundle
                                                                  securityApplicationGroupIdentifier:(NSString *)a_securityApplicationGroupIdentifier
                                                                                               error:(NSError **)a_error {
    NSLog(@"Checking if container migration is required...");
    NSURL *privateContainerStoreUrl = [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                                databaseResourceRelativeFolderPath:nil
                                                securityApplicationGroupIdentifier:nil];
    NSLog(@"  privateContainerStoreUrl = %@", privateContainerStoreUrl);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:privateContainerStoreUrl.path]) {

        NSLog(@"  ...required!");

        NSURL *groupContainerStoreBaseUrl = [self IFA_sqlStoreBaseUrlWithSecurityApplicationGroupIdentifier:a_securityApplicationGroupIdentifier];

        // Remove destination directory if already exists (i.e. from a previous failed migration)
        {
            NSError *error;
            NSLog(@"  Removing directory and its contents...");
            BOOL success = [fileManager removeItemAtURL:groupContainerStoreBaseUrl
                                                  error:&error];
            if (!success) {
                NSLog(@"    directory removal error = %@", error);
                if (a_error) {
                    *a_error = error;
                }
                return NO;
            }
            NSLog(@"    ...directory and contents removed");
        }

        // Create destination directory
        {
            NSLog(@"  Creating directory...");
            NSError *error;
            BOOL success = [fileManager createDirectoryAtURL:groupContainerStoreBaseUrl
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error];
            if (!success) {
                NSLog(@"    directory creation error = %@", error);
                if (a_error) {
                    *a_error = error;
                }
                return NO;
            }
            NSLog(@"    ...directory created");
        }

        NSManagedObjectModel *managedObjectModel = [self IFA_managedObjectModelForResourceNamed:a_managedObjectModelResourceName
                                                                                        version:nil
                                                                                       inBundle:a_managedObjectModelResourceBundle];
        NSString *persistentStoreType = NSSQLiteStoreType;

        // Perform the Core Data migration
        {
            NSPersistentStoreCoordinator *persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];
            NSPersistentStore *oldPersistentStore = [self IFA_addPersistentStoreWithType:persistentStoreType
                                                                                  andUrl:privateContainerStoreUrl
                                                            toPersistentStoreCoordinator:persistentStoreCoordinator
                                                                                readOnly:NO];
            NSURL *groupContainerStoreUrl = [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                                      databaseResourceRelativeFolderPath:nil
                                                      securityApplicationGroupIdentifier:a_securityApplicationGroupIdentifier];
            NSLog(@"  groupContainerStoreUrl = %@", groupContainerStoreUrl);
            NSError *error;
            NSLog(@"  Migrating...");
            NSPersistentStore *newPersistenceStore = [persistentStoreCoordinator migratePersistentStore:oldPersistentStore
                                                                                                  toURL:groupContainerStoreUrl
                                                                                                options:nil
                                                                                               withType:persistentStoreType
                                                                                                  error:&error];
            if (!newPersistenceStore) {
                NSLog(@"    migration error = %@", error);
                if (a_error) {
                    *a_error = error;
                }
                return NO;
            }
            NSLog(@"    ...migration completed");
        }

        // Remove the old persistent store
        {
            NSURL *privateContainerStoreBaseUrl = [self IFA_sqlStoreBaseUrlWithSecurityApplicationGroupIdentifier:nil];
            NSError *error;
            NSLog(@"  Removing old persistent store files...");
            NSArray *contents = [fileManager contentsOfDirectoryAtURL:privateContainerStoreBaseUrl
                                           includingPropertiesForKeys:nil
                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                error:&error];
            if (contents) {
                for (NSURL *url in contents) {
                    if ([url.lastPathComponent hasPrefix:[NSString stringWithFormat:@"%@.", a_databaseResourceName]]) {
                        NSLog(@"    Removing file at %@", url);
                        BOOL success = [fileManager removeItemAtURL:url
                                                              error:&error];
                        if (!success) {
                            NSLog(@"      file removal error = %@", error);
                            if (a_error) {
                                *a_error = error;
                            }
                            return NO;
                        }
                        NSLog(@"      ...file removed");
                    }
                }
            } else {
                NSLog(@"    contens discovery error = %@", error);
                if (a_error) {
                    *a_error = error;
                }
                return NO;
            }
            NSLog(@"    ...old persistent store files removed");
        }

        return YES;

    } else {
        NSLog(@"  ...NOT required.");
        return YES;
    }
}

- (void)configureWithDatabaseResourceName:(NSString *)a_databaseResourceName
       databaseResourceRelativeFolderPath:(NSString *)a_databaseResourceRelativeFolderPath
       databaseResourceAbsoluteFolderPath:(NSString *)a_databaseResourceAbsoluteFolderPath
           managedObjectModelResourceName:(NSString *)a_managedObjectModelResourceName
         managedObjectModelResourceBundle:(NSBundle *)a_managedObjectModelResourceBundle
                managedObjectModelVersion:(NSNumber *)a_managedObjectModelVersion
                              mergePolicy:(NSMergePolicy *)a_mergePolicy
                       entityConfigBundle:(NSBundle *)a_entityConfigBundle
       securityApplicationGroupIdentifier:(NSString *)a_securityApplicationGroupIdentifier
                  muteChangeNotifications:(BOOL)a_muteChangeNotifications
                                 readOnly:(BOOL)a_readOnly {

    // Remove any active observers in case this method is called multiple times (this should happen only in a unit testing scenario)
    if (_IFA_observingManagedObjectContext) {
        [self IFA_removeObservers];
    }

    // SQLite or InMemory store type?
    NSURL *dataStoreUrl;
    NSString *persistentStoreType;
    if (a_databaseResourceName) {
        if (a_databaseResourceAbsoluteFolderPath) {
            dataStoreUrl = [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                     databaseResourceAbsoluteFolderPath:a_databaseResourceAbsoluteFolderPath];
        } else {
            dataStoreUrl = [self IFA_sqlStoreUrlForDatabaseResourceName:a_databaseResourceName
                                     databaseResourceRelativeFolderPath:a_databaseResourceRelativeFolderPath
                                     securityApplicationGroupIdentifier:a_securityApplicationGroupIdentifier];
        }
        persistentStoreType = NSSQLiteStoreType;
    } else {
        dataStoreUrl = nil;
        persistentStoreType = NSInMemoryStoreType;
    }

#ifdef DEBUG
    NSLog(@"Data store URL: %@", dataStoreUrl);
#endif

    // Create data store directory if required
    if (persistentStoreType == NSSQLiteStoreType) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *storeDirectoryUrl = [dataStoreUrl URLByDeletingLastPathComponent];
        NSString *storeDirectoryPath = storeDirectoryUrl.path;
#ifdef DEBUG
        NSLog(@"Checking if data store directory exists: %@", storeDirectoryPath);
#endif
        if (![fileManager fileExistsAtPath:storeDirectoryPath]) {
#ifdef DEBUG
            NSLog(@"  Creating data store directory...");
#endif
            NSError *error;
            BOOL success = [fileManager createDirectoryAtURL:storeDirectoryUrl
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error];
            if (!success) {
                [IFAUIUtils handleUnrecoverableError:error];
                return;
            }
#ifdef DEBUG
            NSLog(@"  ...done");
#endif
        }
    }

    // Configure managedObjectModel
    self.managedObjectModel = [self IFA_managedObjectModelForResourceNamed:a_managedObjectModelResourceName
                                                                   version:a_managedObjectModelVersion
                                                                  inBundle:a_managedObjectModelResourceBundle];

    // Configure persistentStoreCoordinator
    self.persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];
    [self IFA_addPersistentStoreWithType:persistentStoreType
                                  andUrl:dataStoreUrl
            toPersistentStoreCoordinator:self.persistentStoreCoordinator
                                readOnly:a_readOnly];

    // Configure parent managedObjectContext using a main queue concurrency type
    self.managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [self.managedObjectContext setPersistentStoreCoordinator:self.persistentStoreCoordinator];
    if (a_mergePolicy) {
        self.managedObjectContext.mergePolicy = a_mergePolicy;
    }

    // Configure child managedObjectContext using a private queue concurrency type (used for async fetches)
    self.privateQueueChildManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [self.privateQueueChildManagedObjectContext setParentContext:self.managedObjectContext];

    // Add observers if required
    if (!a_muteChangeNotifications) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNotification:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:self.managedObjectContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNotification:)
                                                     name:NSManagedObjectContextWillSaveNotification
                                                   object:self.managedObjectContext];
        self.IFA_observingManagedObjectContext = YES;
    }

    // Instantiate entity configuration
    self.entityConfig = [[IFAEntityConfig alloc] initWithManagedObjectContext:self.managedObjectContext
                                                                       bundle:a_entityConfigBundle];

}

- (void)manageDatabaseVersioningChangeWithSystemEntityConfigBundle:(NSBundle *)a_systemEntityConfigBundle
                                                             block:(void (^)(NSUInteger a_oldSystemEntitiesVersion, NSUInteger a_newSystemEntitiesVersion))a_block {
    
    NSDictionary *l_systemEntityConfig = [IFAUtils getPlistAsDictionary:@"SystemEntityConfig" bundle:a_systemEntityConfigBundle];
    NSUInteger l_newSystemEntitiesVersion = [(NSNumber*)[l_systemEntityConfig valueForKey:@"version"] intValue];
    NSUInteger l_oldSystemEntitiesVersion = [self systemDbTablesVersion];
    [IFAUtils logBooleanWithLabel:@"System tables loaded" value:[self systemDbTablesLoaded]];
    NSLog(@"System tables version - old: %lu, new: %lu", (unsigned long)l_oldSystemEntitiesVersion, (unsigned long)l_newSystemEntitiesVersion);
	if (![self systemDbTablesLoaded] || l_newSystemEntitiesVersion>l_oldSystemEntitiesVersion) {

        NSLog(@"Loading system tables...");

        NSArray *l_systemEntities = [l_systemEntityConfig valueForKey:@"entities"];
        for (NSDictionary *l_systemEntityDictionary in l_systemEntities) {
            NSString *l_entityName = [l_systemEntityDictionary valueForKey:@"name"];

            // Take a snapshot of the system entities' current state (this to prevent Core Data issues when iterating while mutating)
            NSMutableDictionary <NSNumber *, IFASystemEntity*> *systemEntitiesById = [NSMutableDictionary new];
            NSArray <IFASystemEntity *> *systemEntities = [self findAllForEntity:l_entityName];
            [systemEntities enumerateObjectsUsingBlock:^(IFASystemEntity *obj, NSUInteger idx, BOOL *stop) {
                systemEntitiesById[obj.systemEntityId] = obj;
            }];

            NSLog(@"System Entity name: %@", l_entityName);
            NSUInteger l_systemTableVersion = [(NSNumber*)[l_systemEntityDictionary valueForKey:@"version"] intValue];
            NSLog(@"System Entity version: %lu", (unsigned long)l_systemTableVersion);
            if (![self systemDbTablesLoaded] || l_systemTableVersion>l_oldSystemEntitiesVersion) {
                NSLog(@"Loading system table...");
                NSArray *l_rows = [l_systemEntityDictionary valueForKey:@"rows"];
                for (NSDictionary *l_row in l_rows) {
                    NSLog(@"Row: %@", [l_row description]);
                    NSNumber *l_systemEntityId = [l_row valueForKey:@"systemEntityId"];
                    NSLog(@"  Checking if system entity instance with id %lu already exists...", (unsigned long)[l_systemEntityId unsignedIntegerValue]);
                    IFASystemEntity *l_systemEntity = systemEntitiesById[l_systemEntityId];
                    NSNumber *l_activeIndicator = [l_row objectForKey:@"active"];
                    BOOL l_isActive = l_activeIndicator ? [l_activeIndicator boolValue] : YES;
                    if (l_systemEntity) {
                        NSLog(@"  Entity instance EXISTS");
                        if (l_isActive) {
                            NSLog(@"    Entity instance will be updated");
                        }else{
                            NSLog(@"    Entity instance will be deleted");
                            [l_systemEntity ifa_deleteWithValidationAlertPresenter:nil];
                        }
                    }else{
                        NSLog(@"  Entity instance does NOT exist");
                        if (l_isActive) {
                            NSLog(@"    Entity instance will be created");
                            l_systemEntity = (IFASystemEntity *) [self instantiate:l_entityName];
                        }else{
                            NSLog(@"    Entity instance will NOT be created (not active)");
                        }
                    }
                    if (l_isActive) {
                        for (NSString *l_key in [l_row allKeys]) {
                            if ([l_key isEqualToString:@"active"]) {
                                continue;
                            }
                            [l_systemEntity setValue:[l_row valueForKey:l_key] forKey:l_key];
                            NSLog(@"      value set for key: %@", l_key);
                        }
                    }
                }
                NSLog(@"System table loaded");
            }else{
                NSLog(@"System table already loaded");
            }
        }

        a_block(l_oldSystemEntitiesVersion, l_newSystemEntitiesVersion);

		[self setSystemDbTablesVersion:l_newSystemEntitiesVersion];
		[self save];

        NSLog(@"System tables loaded");

	}else{
        NSLog(@"System tables already loaded");
    }
    
}

- (BOOL)validateForSave:(NSManagedObject *)aManagedObject validationAlertPresenter:(UIViewController *)a_validationAlertPresenter{
	NSError *error;
	BOOL coreDataValidationOk;
	if([aManagedObject isInserted]){
		coreDataValidationOk = [aManagedObject validateForInsert:&error];
	}else {
		coreDataValidationOk = [aManagedObject validateForUpdate:&error];
	}
	// Core data model validation
	if (coreDataValidationOk) {
		// Custom managed object validation
		if ([aManagedObject ifa_validateForSave:&error]) {
			// Custom unique key checks
			if([self validateUniqueKeysForManagedObject:aManagedObject error:&error]){
				return YES;
			}
		}
	}
	[self handleCoreDataError:error withManagedObject:aManagedObject alertTitle:nil alertPresenter:a_validationAlertPresenter];
	return NO;
}

- (void)pushChildManagedObjectContext{
    NSManagedObjectContext *l_moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    l_moc.parentContext = self.managedObjectContext;
    [self.IFA_childManagedObjectContexts addObject:l_moc];
//    NSLog(@"AFTER pushChildManagedObjectContext | self.IFA_childManagedObjectContexts.count = %u", self.IFA_childManagedObjectContexts.count);
}

- (void)popChildManagedObjectContext{
    [self.IFA_childManagedObjectContexts removeLastObject];
//    NSLog(@"AFTER popChildManagedObjectContext | self.IFA_childManagedObjectContexts.count = %u", self.IFA_childManagedObjectContexts.count);
}

- (NSArray *)childManagedObjectContexts {
    return self.IFA_childManagedObjectContexts;
}

- (void)removeAllChildManagedObjectContexts {
    [self.IFA_childManagedObjectContexts removeAllObjects];
}

-(void)setIsCurrentManagedObjectDirty:(BOOL)isCurrentManagedObjectDirty{
    [self currentManagedObjectContext].ifa_isCurrentManagedObjectDirty = isCurrentManagedObjectDirty;
}

-(BOOL)isCurrentManagedObjectDirty{
    return [self currentManagedObjectContext].ifa_isCurrentManagedObjectDirty;
}

-(NSManagedObjectContext*)currentManagedObjectContext{
//    NSLog(@" ");
//    NSLog(@"currentManagedObjectContext");
    NSManagedObjectContext *l_managedObjectContext = [[NSThread currentThread] threadDictionary][self.threadDictionaryKeyManagedObjectContext];
//    NSLog(@"  from threadDictionary: %@", [l_managedObjectContext description]);
    if (!l_managedObjectContext) {
        if (self.IFA_childManagedObjectContexts.count>0) {
            l_managedObjectContext = [self.IFA_childManagedObjectContexts lastObject];
//            NSLog(@"  from stack: %@", [l_managedObjectContext description]);
        }else{
            l_managedObjectContext = self.managedObjectContext;
//            NSLog(@"  from main: %@", [l_managedObjectContext description]);
        }
    }
//    NSLog(@" ");
    return l_managedObjectContext;
}

- (NSFetchRequest *)findAllFetchRequest:(NSString *)entityName
                  includePendingChanges:(BOOL)a_includePendingChanges {
    return [self findAllFetchRequest:entityName
               includePendingChanges:a_includePendingChanges
                 usedForRelationship:NO];
}

- (NSFetchRequest *)findAllFetchRequest:(NSString *)entityName
                  includePendingChanges:(BOOL)a_includePendingChanges
                      usedForRelationship:(BOOL)a_usedForRelationship {
	NSEntityDescription *entityDescription = [NSEntityDescription entityForName:entityName inManagedObjectContext:[self currentManagedObjectContext]];
	NSFetchRequest *request = [[NSFetchRequest alloc] init];
    request.includesPendingChanges = a_includePendingChanges;
	[request setEntity:entityDescription];
    if (![self isInMemoryListSortForEntity:entityName
                       usedForRelationship:a_usedForRelationship]) {
        NSArray *l_sortDescriptors = [self listSortDescriptorsForEntity:entityName
                                                      usedForRelationship:a_usedForRelationship];
        //        NSLog(@"findAllFetchRequest sortDescriptors: %@", [l_sortDescriptors description]);
        [request setSortDescriptors:l_sortDescriptors];
    }
	return request;
}

- (NSArray*) executeFetchRequest:(NSFetchRequest*)aFetchRequest{
    
    //    NSLog(@"executeFetchRequest thread: %@", [[NSThread currentThread] description]);
    //    NSLog(@"stack: %@", [NSThread callStackSymbols]);
    
    NSError *error;
	NSArray *resultArray = [[self currentManagedObjectContext] executeFetchRequest:aFetchRequest error:&error];
	
	if(resultArray==nil){
		[IFAUIUtils handleUnrecoverableError:error];
	}
	
	return resultArray;
	
}

- (NSMutableArray*) executeFetchRequestMutable:(NSFetchRequest*)aFetchRequest{
	return [[NSMutableArray alloc] initWithArray:[self executeFetchRequest:aFetchRequest]];
}

- (NSFetchRequest*) fetchRequestWithPredicate:(NSPredicate*)aPredicate
                              sortDescriptors:(NSArray*)aSortDescriptorArray
                                       entity:(NSString*)anEntityName{
    return [self fetchRequestWithPredicate:aPredicate sortDescriptors:aSortDescriptorArray entity:anEntityName limit:0 countOnly:NO];
}

- (NSFetchRequest*) fetchRequestWithPredicate:(NSPredicate*)aPredicate
                              sortDescriptors:(NSArray*)aSortDescriptorArray
                                       entity:(NSString*)anEntityName
                                        limit:(NSUInteger)aLimit
                                    countOnly:(BOOL)aCountOnlyFlag{
	
	NSFetchRequest *request = [[NSFetchRequest alloc] init];
    
	if (aPredicate) {
		[request setPredicate:aPredicate];
	}
	if(aSortDescriptorArray){
		[request setSortDescriptors:aSortDescriptorArray];
	}
    if(aLimit){
        request.fetchLimit = aLimit;
    }
    if(aCountOnlyFlag){
        request.resultType = NSCountResultType;
    }
	
	// Entity description
	NSEntityDescription *entityDescription = [NSEntityDescription entityForName:anEntityName inManagedObjectContext:[self currentManagedObjectContext]];
	[request setEntity:entityDescription];
    
    return request;
    
}

- (NSMutableArray *)inMemorySortObjects:(NSMutableArray *)objects
                          ofEntityNamed:(NSString *)entityName
                    usedForRelationship:(BOOL)usedForRelationship {
    if ([self isInMemoryListSortForEntity:entityName
                      usedForRelationship:usedForRelationship]) {
//        NSLog(@"in memory sorting: %@", [a_array description]);
        [objects sortUsingDescriptors:[self listSortDescriptorsForEntity:entityName
                                                     usedForRelationship:usedForRelationship]];
//        NSLog(@"SORTED: %@", [a_array description]);
    }
    return objects;
}

- (BOOL)unsavedEditingChanges {
    BOOL dirty = self.managedObjectContext.ifa_isCurrentManagedObjectDirty;
    if (!dirty) {
        for (NSManagedObjectContext *childManagedObjectContext in self.childManagedObjectContexts) {
            if ((dirty = childManagedObjectContext.ifa_isCurrentManagedObjectDirty)) {
                break;
            }
        }
    }
    return dirty;
}

+ (instancetype)sharedInstance {
    static dispatch_once_t c_dispatchOncePredicate;
    static id c_instance = nil;
    dispatch_once(&c_dispatchOncePredicate, ^{
        c_instance = [self new];
    });
    return c_instance;
}

+ (BOOL)setValidationError:(NSError**)anError withMessage:(NSString*)anErrorMessage{
	if (anError!=NULL) {
		*anError = [IFAUIUtils newErrorWithCode:IFAErrorPersistenceValidation errorMessage:anErrorMessage];
		return NO;
	}else {
		return YES;
	}
}

+ (NSMutableArray*)idsForManagedObjects:(NSArray*)a_managedObjects{
    return [a_managedObjects valueForKey:@"objectID"];
}

+ (NSSet *)insertedObjectsInPersistentEntityChangeNotificationUserInfo:(NSDictionary *)userInfo {
    return userInfo[IFAKeyInsertedObjects];
}

+ (NSSet *)deletedObjectsInPersistentEntityChangeNotificationUserInfo:(NSDictionary *)userInfo {
    return userInfo[IFAKeyDeletedObjects];
}

+ (NSSet *)updatedObjectsInPersistentEntityChangeNotificationUserInfo:(NSDictionary *)userInfo {
    return userInfo[IFAKeyUpdatedObjects];
}

+ (NSDictionary *)originalPropertiesInPersistentEntityChangeNotificationUserInfo:(NSDictionary *)userInfo {
    return userInfo[IFAKeyOriginalProperties];
}

+ (NSDictionary *)updatedPropertiesInPersistentEntityChangeNotificationUserInfo:(NSDictionary *)userInfo {
    return userInfo[IFAKeyUpdatedProperties];
}

- (NSArray <NSManagedObject *> *)syncEntityNamed:(NSString *)entityName
                               withSourceObjects:(NSArray *)sourceObjects
                                  keyPathMapping:(NSDictionary *)keyPathMapping
                                 sourceIdKeyPath:(NSString *)sourceIdKeyPath
                                 targetIdKeyPath:(NSString *)targetIdKeyPath
                                    mappingBlock:(void (^)(id sourceObject, NSManagedObject *targetManagedObject))mappingBlock {
    NSMutableArray <NSManagedObject *> *synchronisedObjects = [NSMutableArray new];
    for (id sourceObject in sourceObjects) {
        id sharedId = [sourceObject valueForKeyPath:sourceIdKeyPath];
        NSManagedObject *managedObject = [self findSingleByKeysAndValues:@{targetIdKeyPath : sharedId}
                                                                  entity:entityName];
        if (!managedObject) {
            managedObject = [self instantiate:entityName];
            [managedObject setValue:sharedId
                         forKeyPath:targetIdKeyPath];
        }
        for (NSString *sourcePropertyName in keyPathMapping.allKeys) {
            id sharedValue = [sourceObject valueForKeyPath:sourcePropertyName];
            [managedObject setValue:sharedValue
                         forKeyPath:keyPathMapping[sourcePropertyName]];
        }
        if (mappingBlock) {
            mappingBlock(sourceObject, managedObject);
        }
        [synchronisedObjects addObject:managedObject];
    }
    NSMutableArray <NSManagedObject *> *managedObjectsToDelete = [self findAllForEntity:entityName];
    [managedObjectsToDelete removeObjectsInArray:synchronisedObjects];
    for (NSManagedObject *managedObjectToDelete in managedObjectsToDelete) {
        [self deleteObject:managedObjectToDelete
  validationAlertPresenter:nil];
    }
    return synchronisedObjects;
}

#pragma mark -
#pragma mark Overrides

- (void)dealloc {
    [self IFA_removeObservers];
}

//#ifdef DEBUG
//- (void)resetTestDatabase:(NSURL*)aUrl{
//	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory , NSUserDomainMask, YES);
//	NSString *documentsDir = [paths objectAtIndex:0];
//	NSString *pathLocal = [documentsDir stringByAppendingPathComponent:DATABASE_NAME];
//	NSFileManager *fileManager = [NSFileManager defaultManager];
//	NSError *error;
//	if ([fileManager fileExistsAtPath:pathLocal]) {
//		if([fileManager removeItemAtURL:aUrl error:&error]){
//			return;
//		}else {
//			[IFAUtils handleUnrecoverableError:error];
//		}
//	}
//}
//#endif

@end
